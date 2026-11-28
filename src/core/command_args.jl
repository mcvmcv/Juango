# Management commands with declared arguments (Django's BaseCommand.add_arguments, #289) -------------------------
#
#     register_command!("dance"; help = "Dance around like a madman.",
#                       arguments = [arg("integer"; nargs = "?", type = Int, default = 0),
#                                    arg("-s", "--style"; default = "Rock'n'Roll"),
#                                    arg("--opt-3"; action = :store_true, dest = :option3)]) do opts
#         opts.verbosity > 0 && println(cmd_stdout(), "I don't feel like dancing ", opts.style, ".")
#     end
#
#     call_command("dance", "--style", "Jive")      # or call_command("dance"; style = "Jive")
#
# The parsing follows Python's argparse as Django uses it (no abbreviated options), with its messages.

"""
    arg(names...; dest, nargs, type, default, action = :store, constant, required = false, choices, help = "")

One argument of a command, as argparse's `add_argument`: a positional (`arg("integer")`) or an option
(`arg("-s", "--style")`). `action` is `:store`, `:store_true`, `:store_false`, `:store_const`, `:append`,
`:append_const` or `:count`; `constant` is argparse's `const`. `nargs` is `"?"`, `"*"`, `"+"` or a number;
`type` converts each value (`Int`, `Float64`, or a function of the string).
"""
struct CommandArg
    names::Vector{String}
    dest::Symbol
    positional::Bool
    nargs::Any
    type::Any
    default::Any
    action::Symbol
    constant::Any
    required::Bool
    choices::Any
    help::String
end
function arg(names::AbstractString...; dest = nothing, nargs = nothing, type = nothing, default = nothing, action::Symbol = :store,
             constant = nothing, required::Bool = false, choices = nothing, help::AbstractString = "")
    isempty(names) && throw(ArgumentError("arg() needs a name"))
    positional = !startswith(names[1], "-")
    long = findfirst(n -> startswith(n, "--"), names)
    d = dest !== nothing ? Symbol(dest) : positional ? Symbol(names[1]) :
        Symbol(replace(lstrip(names[something(long, 1)], '-'), '-' => '_'))
    action in (:store, :store_true, :store_false, :store_const, :append, :append_const, :count) ||
        throw(ArgumentError("arg(): unknown action :$action"))
    dflt = default !== nothing ? default : action === :store_true ? false : action === :store_false ? true : nothing
    CommandArg(String[string(n) for n in names], d, positional, nargs, type, dflt, action, constant, required || (positional && nargs in (nothing, "+") || nargs isa Integer), choices, String(help))
end
"Arguments of which at most one may be given (`required = true`: exactly one), as argparse's add_mutually_exclusive_group."
struct ExclusiveGroup
    args::Vector{CommandArg}
    required::Bool
end
exclusive_group(args::CommandArg...; required::Bool = false) = ExclusiveGroup(collect(args), required)

struct DeclaredCommand
    name::String
    help::String
    arguments::Vector{CommandArg}
    groups::Vector{ExclusiveGroup}
    requires_system_checks::Any        # [] (none), "__all__", or tags
    handle::Function
end

"The options every command has, as Django's BaseCommand."
const COMMON_ARGS = [arg("--version"; action = :store_true, help = "Show program's version number and exit."),
                     arg("-v", "--verbosity"; type = Int, default = 1, choices = [0, 1, 2, 3],
                         help = "Verbosity level; 0=minimal output, 1=normal output, 2=verbose output, 3=very verbose output"),
                     arg("--settings"; help = "Not used by Juango (settings are the project's configure! call)."),
                     arg("--pythonpath"; help = "Not used by Juango."),
                     arg("--traceback"; action = :store_true, help = "Raise on CommandError exceptions."),
                     arg("--no-color"; action = :store_true, help = "Don't colorize the command output."),
                     arg("--force-color"; action = :store_true, help = "Force colorization of the command output."),
                     arg("--skip-checks"; action = :store_true, help = "Skip system checks.")]

const DECLARED_COMMANDS = Dict{String,DeclaredCommand}()

"""
    register_command!(handle, name; help = "", arguments = [], requires_system_checks = "__all__")

Register a command with declared arguments: `handle(opts)` gets a NamedTuple of the parsed arguments
(by `dest`) and the common options (`verbosity`, `traceback`, `no_color`, `force_color`, `skip_checks`).
`arguments` holds `arg(...)`s and `exclusive_group(...)`s. `requires_system_checks` (`[]`, `"__all__"` or
check tags) runs the system checks first when run from the command line (`--skip-checks` skips them) or
from `call_command(...; skip_checks = false)`, failing on errors, as Django's.
"""
function register_command!(handle::Function, name::AbstractString; help::AbstractString = "", arguments = Any[],
                           requires_system_checks = "__all__")
    requires_system_checks == "__all__" || requires_system_checks isa Union{AbstractVector,Tuple} ||
        throw(ArgumentError("requires_system_checks must be a list or tuple."))
    args, groups = CommandArg[], ExclusiveGroup[]
    for a in arguments
        if a isa ExclusiveGroup
            push!(groups, a); append!(args, a.args)
        else
            push!(args, a)
        end
    end
    for a in args, c in COMMON_ARGS
        any(in(c.names), a.names) && throw(ArgumentError("argument $(join(a.names, "/")): conflicting option string: $(first(filter(in(c.names), a.names)))"))
    end
    cmd = DeclaredCommand(String(name), String(help), args, groups, requires_system_checks, handle)
    DECLARED_COMMANDS[cmd.name] = cmd
    COMMANDS[cmd.name] = (cmd.help, words -> run_declared(cmd, words, (;); from_code = false))
    nothing
end

argerror(msg) = throw(CommandError("Error: " * msg))
choice_error(label, v, choices) = argerror("argument $label: invalid choice: $(repr(v)) (choose from $(join(repr.(choices), ", ")))")
"The DATABASES aliases, \"default\" first: the choices of every command's --database (Django's)."
database_aliases() = sort!(collect(keys(database_settings())); by = a -> (a != "default", a))
"Refuse a --database that isn't a DATABASES alias, with argparse's message (#303)."
check_database_option(v) = (v === nothing || v in database_aliases() || choice_error("--database", v, database_aliases()); v)
arg_label(a::CommandArg) = a.positional ? string(a.dest) : join(a.names, "/")

function convert_value(a::CommandArg, v)
    t = a.type
    x = if t === nothing || !(v isa AbstractString)
        v
    elseif t isa Type && t <: Number
        r = tryparse(t, v)
        r === nothing && argerror("argument $(arg_label(a)): invalid $(t <: Integer ? "int" : "float") value: '$v'")
        r
    else
        try
            t(v)
        catch
            argerror("argument $(arg_label(a)): invalid $(t) value: '$v'")
        end
    end
    # (choices may be a function, called when parsing: DATABASES' aliases for --database)
    ch = a.choices isa Function ? a.choices() : a.choices
    ch === nothing || x in ch || choice_error(arg_label(a), v isa AbstractString ? v : string(v), ch)
    x
end

"Parse the words: the values given, by dest, and which arguments were given."
function parse_command_words(cmd::DeclaredCommand, words::Vector{String})
    all_args = vcat(cmd.arguments, COMMON_ARGS)
    opts = Dict{Symbol,Any}()
    given = Set{CommandArg}()
    positionals = String[]
    byname = Dict{String,CommandArg}(n => a for a in all_args if !a.positional for n in a.names)
    takes_value(a) = a.action in (:store, :append)
    function set!(a, v)
        push!(given, a)
        if a.action === :store
            opts[a.dest] = a.nargs in ("*", "+") || a.nargs isa Integer ? [convert_value(a, x) for x in v] : convert_value(a, v)
        elseif a.action === :append
            push!(get!(() -> Any[], opts, a.dest), convert_value(a, v))
        elseif a.action === :store_true
            opts[a.dest] = true
        elseif a.action === :store_false
            opts[a.dest] = false
        elseif a.action === :store_const
            opts[a.dest] = a.constant
        elseif a.action === :append_const
            push!(get!(() -> Any[], opts, a.dest), a.constant)
        elseif a.action === :count
            opts[a.dest] = something(get(opts, a.dest, nothing), 0) + 1
        end
    end
    isnum(w) = tryparse(Float64, w) !== nothing
    i = 1
    rest = false
    while i <= length(words)
        w = words[i]
        if rest || !startswith(w, "-") || w == "-" || isnum(w)
            push!(positionals, w)
        elseif w == "--"
            rest = true
        else
            name, inline = startswith(w, "--") ? (occursin('=', w) ? String.(split(w, '='; limit = 2)) : (w, nothing)) :
                           (length(w) > 2 ? (w[1:2], w[3:end]) : (w, nothing))
            a = get(byname, name, nothing)
            a === nothing && argerror("unrecognized arguments: $w")
            if takes_value(a)
                if a.nargs in ("*", "+")
                    vals = inline === nothing ? String[] : [inline]
                    while i < length(words) && !(startswith(words[i+1], "-") && !isnum(words[i+1]))
                        push!(vals, words[i+1]); i += 1
                    end
                    a.nargs == "+" && isempty(vals) && argerror("argument $(arg_label(a)): expected at least one argument")
                    set!(a, vals)
                else
                    v = inline
                    if v === nothing
                        if i < length(words) && !(startswith(words[i+1], "-") && !isnum(words[i+1]))
                            v = words[i+1]; i += 1
                        elseif a.nargs == "?"
                            push!(given, a); opts[a.dest] = a.constant      # (an optional value left out: const)
                            i += 1
                            continue
                        else
                            argerror("argument $(arg_label(a)): expected one argument")
                        end
                    end
                    set!(a, v)
                end
            else
                inline === nothing || argerror("argument $(arg_label(a)): ignored explicit argument '$inline'")
                set!(a, nothing)
            end
        end
        i += 1
    end
    # positionals in order: each takes what it needs, leaving enough for the required ones after it
    pargs = [a for a in all_args if a.positional]
    need(a) = a.nargs === nothing ? 1 : a.nargs == "+" ? 1 : a.nargs isa Integer ? a.nargs : 0
    k = 1
    for (j, a) in enumerate(pargs)
        left = length(positionals) - k + 1
        after = sum(need, pargs[j+1:end]; init = 0)
        avail = max(left - after, 0)
        n = a.nargs === nothing ? min(1, avail) : a.nargs == "?" ? min(1, avail) : a.nargs isa Integer ? min(a.nargs, avail) : avail
        if n > 0
            vals = positionals[k:k+n-1]
            k += n
            a.nargs === nothing || a.nargs == "?" ? set!(a, vals[1]) : set!(a, vals)
        end
    end
    k <= length(positionals) && argerror("unrecognized arguments: $(join(positionals[k:end], " "))")
    opts, given
end

function run_declared(cmd::DeclaredCommand, words::Vector{String}, options; from_code::Bool)
    all_args = vcat(cmd.arguments, COMMON_ARGS)
    "--help" in words || "-h" in words ? (return print_command_help(cmd)) : nothing
    opts, given = parse_command_words(cmd, words)
    # options given as keywords (call_command): by dest, or by an option's name (opt_3 for --opt-3), values as they are
    if !isempty(options)
        keyname(n) = replace(lstrip(n, '-'), '-' => '_')
        valid = sort(unique(vcat([string(a.dest) for a in all_args], [keyname(n) for a in all_args for n in a.names if startswith(n, "--")],
                                 ["help", "stdout", "stderr"])))
        unknown = sort([string(k) for k in keys(options) if !(string(k) in valid)])
        isempty(unknown) || throw(ArgumentError("Unknown option(s) for $(cmd.name) command: $(join(unknown, ", ")). Valid options are: $(join(valid, ", "))."))
        for (k, v) in pairs(options)
            matches = [a for a in all_args if string(a.dest) == string(k)]
            isempty(matches) && (matches = [a for a in all_args if any(n -> !a.positional && keyname(n) == string(k), a.names)])
            length(matches) > 1 && throw(ArgumentError("Cannot pass the dest '$k' that matches multiple arguments via **options."))
            a = only(matches)
            push!(given, a)
            opts[a.dest] = v
        end
    end
    # mutually exclusive groups, then required arguments (argparse's order and messages)
    for g in cmd.groups
        gs = [a for a in g.args if a in given]
        length(gs) > 1 && argerror("argument $(arg_label(gs[2])): not allowed with argument $(arg_label(gs[1]))")
        g.required && isempty(gs) && argerror("one of the arguments $(join([a.positional ? string(a.dest) : join(a.names, " ") for a in g.args], " ")) is required")
    end
    missing_args = [arg_label(a) for a in all_args if a.required && !(a in given) && !any(g -> a in g.args, cmd.groups)]
    isempty(missing_args) || argerror("the following arguments are required: $(join(missing_args, ", "))")
    for a in all_args
        haskey(opts, a.dest) || (opts[a.dest] = a.action === :count ? something(a.default, 0) : a.default)
    end
    opts[:verbosity] = Int(opts[:verbosity])
    for (k, v) in opts                                        # (appended values: a vector of their type, [42] not Any[42])
        v isa Vector{Any} && !isempty(v) && (opts[k] = [x for x in v])
    end
    if opts[:version]
        println(cmd_stdout(), pkgversion(@__MODULE__))
        return nothing
    end
    # system checks: from the command line unless --skip-checks; from call_command only with skip_checks = false
    skip = from_code ? get(options, :skip_checks, true) : opts[:skip_checks]
    if !(skip === true) && cmd.requires_system_checks != Any[] && !(cmd.requires_system_checks isa Union{AbstractVector,Tuple} && isempty(cmd.requires_system_checks))
        msgs = cmd.requires_system_checks == "__all__" ? run_checks() : run_checks(; tags = collect(cmd.requires_system_checks))
        serious = filter(is_serious, msgs)
        isempty(serious) || throw(CommandError("System check identified some issues:\n" * join(string.(serious), "\n")))
    end
    nt = NamedTuple{Tuple(keys(opts))}(Tuple(values(opts)))
    opts[:no_color] && opts[:force_color] && throw(CommandError("The --no-color and --force-color options can't be used together."))
    style = opts[:no_color] ? no_style() : color_style(; force_color = opts[:force_color], io = cmd_stdout())
    Base.ScopedValues.with(() -> cmd.handle(nt), COMMAND_STYLE => style)
end

"The style of the running command's output (Django's `self.style`): colors unless `--no-color` or not a terminal."
const COMMAND_STYLE = Base.ScopedValues.ScopedValue{Union{Nothing,Style}}(nothing)
cmd_style() = something(COMMAND_STYLE[], no_style())
"""
    cmd_write(msg; style = nothing, ending = "\n", err = false)

Write a line of command output (Django's `self.stdout.write(msg, style_func)`): `style` is a role of the
command's style (`:SUCCESS`, `:ERROR`, ...) or a function; `err = true` writes to the command's stderr.
"""
function cmd_write(msg; style = nothing, ending = "\n", err::Bool = false)
    text = endswith(string(msg), ending) ? string(msg) : string(msg, ending)
    f = style === nothing ? identity : style isa Symbol ? getproperty(cmd_style(), style) : style
    print(err ? cmd_stderr() : cmd_stdout(), f(text))
    nothing
end

function print_command_help(cmd::DeclaredCommand)
    io = cmd_stdout()
    all_args = vcat(cmd.arguments, COMMON_ARGS)
    usage(a) = a.positional ? (a.nargs == "?" ? "[$(a.dest)]" : a.nargs in ("*", "+") ? "$(a.dest) ..." : string(a.dest)) :
               (a.required ? "" : "[") * a.names[end] * (a.action in (:store, :append) ? " " * uppercase(string(a.dest)) : "") * (a.required ? "" : "]")
    println(io, "usage: manage.jl ", cmd.name, " ", join(usage.(vcat(filter(a -> !a.positional, all_args), filter(a -> a.positional, all_args))), " "))
    isempty(cmd.help) || println(io, "\n", cmd.help)
    pos = filter(a -> a.positional, all_args)
    isempty(pos) || (println(io, "\npositional arguments:"); foreach(a -> println(io, "  ", rpad(string(a.dest), 24), a.help), pos))
    println(io, "\noptions:")
    println(io, "  ", rpad("-h, --help", 24), "show this help message and exit")
    for a in filter(a -> !a.positional, all_args)
        println(io, "  ", rpad(join(a.names, ", ") * (a.action in (:store, :append) ? " " * uppercase(string(a.dest)) : ""), 24), a.help)
    end
    nothing
end
