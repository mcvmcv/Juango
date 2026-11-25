# Django's user_commands tests, ported (#227): tests/user_commands (CommandTests), with its commands
# (dance, hal, required_option, mutually_exclusive_required, ...) declared with `register_command!`'s
# `arguments` (#289). Output goes to `cmd_stdout()` (Django's self.stdout).
# julia --project=test test/django_user_commands.jl   (see setup.jl)
#
# Each test keeps its Django name in a comment.
@isdefined(TEST_SETUP_DONE) || include("setup.jl")

using Juango: arg, exclusive_group, cmd_stdout
out_of(f) = (io = IOBuffer(); f(io); String(take!(io)))
writeopts(opts; skipnothing = true) = foreach(k -> (v = opts[k]; skipnothing && v === nothing || println(cmd_stdout(), k, "=", v)), keys(opts))

register_command!("dance"; help = "Dance around like a madman.",
                  arguments = [arg("integer"; nargs = "?", type = Int, default = 0), arg("-s", "--style"; default = "Rock'n'Roll"),
                               arg("-x", "--example"), arg("--opt-3"; action = :store_true, dest = :option3)]) do opts
    opts.example == "raise" && throw(CommandError(; returncode = 3))
    if opts.verbosity > 0
        println(cmd_stdout(), "I don't feel like dancing ", opts.style, ".")
        println(cmd_stdout(), join(string.(keys(opts)), ","))
    end
    opts.integer > 0 && println(cmd_stdout(), "You passed ", opts.integer, " as a positional argument.")
end
register_command!("hal"; help = "Useless command.",
                  arguments = [arg("args"; nargs = "*", help = "Specify the app label(s) to works on."), arg("--empty"; action = :store_true)]) do opts
    if opts.empty
        println(cmd_stdout()); println(cmd_stdout(), "Dave, I can't do that.")
        return
    end
    labels = something(opts.args, String[])
    isempty(labels) && throw(CommandError("I'm sorry Dave, I'm afraid I can't do that."))
    any(l -> startswith(l, "--"), labels) && throw(CommandError("Sorry, Dave, I can't let you do that."))
    println(cmd_stdout(), "Dave, my mind is going. I can feel it. I can feel it.")
end
register_command!(o -> println(cmd_stdout(), join(string.(keys(o)), ",")), "required_option";
                  arguments = [arg("-n", "--need-me"; required = true), arg("-t", "--need-me-too"; required = true, dest = :needme2)])
register_command!(writeopts, "mutually_exclusive_required";
                  arguments = [exclusive_group(arg("--foo-id"; type = Int, nargs = "?"), arg("--foo-name"; nargs = "?"),
                                               arg("--foo-list"; type = Int, nargs = "+"), arg("--append_const"; action = :append_const, constant = 42),
                                               arg("--const"; action = :store_const, constant = 31), arg("--count"; action = :count),
                                               arg("--flag_false"; action = :store_false, default = nothing),
                                               arg("--flag_true"; action = :store_true, default = nothing); required = true)])
register_command!(writeopts, "mutually_exclusive_required_with_same_dest";
                  arguments = [exclusive_group(arg("--for"; dest = :until), arg("--until"); required = true)])
register_command!(writeopts, "required_constant_option";
                  arguments = [arg("--append_const"; action = :append_const, constant = 42, required = true),
                               arg("--const"; action = :store_const, constant = 31, required = true),
                               arg("--count"; action = :count, required = true),
                               arg("--flag_false"; action = :store_false, required = true),
                               arg("--flag_true"; action = :store_true, required = true)])
register_command!(o -> writeopts(o; skipnothing = false), "required_list_option"; arguments = [arg("--foo-list"; nargs = "+", type = Int, required = true)])
const DUC_CHECKS = Ref(0)
register_command!(o -> nothing, "no_system_checks"; requires_system_checks = [])
register_check!(tags = [:duc_tag]) do
    DUC_CHECKS[] += 1
    CheckMessage[]
end
register_command!(o -> nothing, "specific_system_checks"; requires_system_checks = [:duc_tag])

@testset "django user_commands: CommandTests" begin
    @test occursin("I don't feel like dancing Rock'n'Roll.\n", out_of(io -> call_command("dance"; stdout = io)))          # test_command
    @test occursin("I don't feel like dancing Jive.\n", out_of(io -> call_command("dance"; style = "Jive", stdout = io)))   # test_command_style
    @test occursin("I don't feel like dancing Jive.\n", out_of(io -> call_command("dance", "--style", "Jive"; stdout = io)))
    @test occursin("I don't feel like dancing Jive.\n", out_of(io -> call_command("dance", "-sJive"; stdout = io)))
    Juango.with_language("fr") do                                                                                       # test_language_preserved
        call_command("dance"; verbosity = 0)
        @test Juango.get_language() == "fr"
    end
    @test_throws "Unknown command: 'explode'" call_command("explode")                                                # test_explode
    e = try call_command("dance"; example = "raise") catch e; e end                                                  # test_system_exit
    @test e isa CommandError && e.returncode == 3
    t = out_of(io -> call_command("dance"; stdout = io, opt_3 = true))                                               # test_call_command_option_parsing
    @test occursin("option3", t) && !occursin("opt_3", t) && !occursin("opt-3", t)
    @test occursin("You passed 1 as a positional argument.", out_of(io -> call_command("dance", 1; verbosity = 0, stdout = io)))   # ..._non_string_arg
    @test out_of(io -> call_command("hal", "--empty"; stdout = io)) == "\nDave, I can't do that.\n"                   # test_calling_a_command_with_only_empty_parameter_should_ends_gracefully
    @test occursin("Dave, my mind is going.", out_of(io -> call_command("hal", "myapp", "--verbosity", "3"; stdout = io)))   # ..._app_labels_and_parameters_should_be_ok
    @test occursin("Dave, my mind is going.", out_of(io -> call_command("hal", "--verbosity", "3", "myapp"; stdout = io)))   # ..._app_labels_at_the_end_should_be_ok
    @test_throws CommandError call_command("hal")                                                                     # ..._no_app_labels_and_parameters_raise_command_error
    # test_call_command_no_checks, test_requires_system_checks_empty, test_requires_system_checks_specific
    n = DUC_CHECKS[]
    call_command("specific_system_checks")
    @test DUC_CHECKS[] == n                                                                                           # (call_command skips them by default)
    call_command("specific_system_checks"; skip_checks = false)
    @test DUC_CHECKS[] == n + 1
    call_command("no_system_checks"; skip_checks = false)
    @test DUC_CHECKS[] == n + 1
    @test_throws "requires_system_checks must be a list or tuple." register_command!(o -> nothing, "bad"; requires_system_checks = "x")   # test_requires_system_checks_invalid
    # test_call_command_unrecognized_option
    valid = "example, force_color, help, integer, no_color, opt_3, option3, pythonpath, settings, skip_checks, stderr, stdout, style, traceback, verbosity, version"
    @test_throws "Unknown option(s) for dance command: unrecognized. Valid options are: $valid." call_command("dance"; unrecognized = 1)
    @test_throws "Unknown option(s) for dance command: unrecognized, unrecognized2. Valid options are: $valid." call_command("dance"; unrecognized = 1, unrecognized2 = 1)
    # test_call_command_with_required_parameters_in_options, ..._in_mixed_options
    t = out_of(io -> call_command("required_option"; need_me = "foo", needme2 = "bar", stdout = io))
    @test occursin("need_me", t) && occursin("needme2", t)
    t = out_of(io -> call_command("required_option", "--need-me=foo"; needme2 = "bar", stdout = io))
    @test occursin("need_me", t) && occursin("needme2", t)
    @test_throws "Error: the following arguments are required: -n/--need-me, -t/--need-me-too" call_command("required_option")
    # test_mutually_exclusive_group_required_options
    @test occursin("foo_id", out_of(io -> call_command("mutually_exclusive_required"; foo_id = 1, stdout = io)))
    @test occursin("foo_name", out_of(io -> call_command("mutually_exclusive_required"; foo_name = "foo", stdout = io)))
    @test_throws "Error: one of the arguments --foo-id --foo-name --foo-list --append_const --const --count --flag_false --flag_true is required" call_command("mutually_exclusive_required")
    @test_throws "Error: argument --foo-name: not allowed with argument --foo-id" call_command("mutually_exclusive_required", "--foo-id", "1", "--foo-name", "x")
    # test_mutually_exclusive_group_required_const_options
    for (a, v) in [("append_const", [42]), ("const", 31), ("count", 1), ("flag_false", false), ("flag_true", true)]
        @test occursin("$a=$v", out_of(io -> call_command("mutually_exclusive_required", "--$a"; stdout = io)))
        @test occursin("$a=$v", out_of(io -> call_command("mutually_exclusive_required"; (Symbol(a) => v,)..., stdout = io)))
    end
    # test_mutually_exclusive_group_required_with_same_dest_options, ..._args
    @test_throws "Cannot pass the dest 'until' that matches multiple arguments via **options." call_command("mutually_exclusive_required_with_same_dest"; until = "2")
    for args in [("--until=1",), ("--until", 1), ("--for=1",), ("--for", 1)]
        @test occursin("until=1", out_of(io -> call_command("mutually_exclusive_required_with_same_dest", args...; stdout = io)))
    end
    # test_required_list_option
    for command in ("mutually_exclusive_required", "required_list_option")
        @test occursin("foo_list=[1, 2]", out_of(io -> call_command(command, "--foo-list", [1, 2]; stdout = io)))
        @test occursin("foo_list=[1, 2]", out_of(io -> call_command(command; foo_list = [1, 2], stdout = io)))
    end
    # test_required_const_options
    t = out_of(io -> call_command("required_constant_option", "--append_const", "--const", "--count", "--flag_false", "--flag_true"; stdout = io))
    @test occursin("append_const=[42]", t) && occursin("const=31", t) && occursin("count=1", t) && occursin("flag_false=false", t) && occursin("flag_true=true", t)
    t = out_of(io -> call_command("required_constant_option"; append_const = [42], (:const => 31,)..., count = 1, flag_false = false, flag_true = true, stdout = io))
    @test occursin("append_const=[42]", t) && occursin("const=31", t) && occursin("count=1", t) && occursin("flag_false=false", t)
    # (argparse's messages for values)
    @test_throws "Error: argument integer: invalid int value: 'x'" call_command("dance", "x")
    @test_throws "Error: argument -v/--verbosity: invalid choice: \"7\" (choose from 0, 1, 2, 3)" call_command("dance", "-v", "7")
    @test_throws "Error: unrecognized arguments: --nope" call_command("dance", "--nope")
    @test_throws "Error: argument -s/--style: expected one argument" call_command("dance", "--style")
    # --help: the declared arguments
    t = out_of(io -> call_command("dance", "--help"; stdout = io))
    @test occursin("usage: manage.jl dance", t) && occursin("Dance around like a madman.", t) && occursin("-s, --style STYLE", t) && occursin("--skip-checks", t)
    # an old-style command takes words only
    @test_throws "Unknown option(s) for migrate command: verbosity" call_command("migrate"; verbosity = 2)
    # not translated: OutputWrapper, @no_translations, find_command and eggs, subparsers (not supported), create_parser's
    # kwargs, requires_migrations_checks, the colour handling of Python 3.14's argparse, CommandRunTests (scripts)
end
