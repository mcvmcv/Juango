# Terminal colors, as Django's django.utils.termcolors and django.core.management.color: ANSI codes
# (`colorize`), named palettes of roles (ERROR, SUCCESS, SQL_KEYWORD, HTTP_NOT_FOUND, ...) and the
# JUANGO_COLORS environment variable (Django's DJANGO_COLORS, which is read too):
#
#     JUANGO_COLORS="light;error=yellow/blue,blink;notice=magenta" julia --project manage.jl migrate
#
# Commands write in the role's style with `cmd_write(msg; style = :SUCCESS)`; `--no-color` and
# `--force-color` turn the colors off or on whatever the terminal.

const TERM_COLOR_NAMES = ("black", "red", "green", "yellow", "blue", "magenta", "cyan", "white")
const TERM_FOREGROUND = Dict(c => "3$(i - 1)" for (i, c) in enumerate(TERM_COLOR_NAMES))
const TERM_BACKGROUND = Dict(c => "4$(i - 1)" for (i, c) in enumerate(TERM_COLOR_NAMES))
const TERM_RESET = "0"
const TERM_OPTS = Dict("bold" => "1", "underscore" => "4", "blink" => "5", "reverse" => "7", "conceal" => "8")

"""
    colorize(text = ""; fg = nothing, bg = nothing, opts = ()) -> String

`text` between ANSI codes for the colors `fg` and `bg` (black, red, green, yellow, blue, magenta, cyan,
white) and the `opts` (bold, underscore, blink, reverse, conceal), then the reset code unless `opts`
has `"noreset"`. `colorize(""; opts = ("reset",))` is the reset code alone. As Django's.
"""
function colorize(text = ""; fg = nothing, bg = nothing, opts = (), kw...)
    text = something(text, "")
    text == "" && length(opts) == 1 && opts[1] == "reset" && return "\e[$(TERM_RESET)m"
    codes = String[]
    fg === nothing || push!(codes, TERM_FOREGROUND[fg])
    bg === nothing || push!(codes, TERM_BACKGROUND[bg])
    for o in opts
        haskey(TERM_OPTS, o) && push!(codes, TERM_OPTS[o])
    end
    "noreset" in opts || (text = string(text, "\e[$(TERM_RESET)m"))
    string("\e[", join(codes, ";"), "m", text)
end
"A function that colorizes its text with these settings (Django's `termcolors.make_style`)."
termcolor_style(; opts = (), fg = nothing, bg = nothing) = text -> colorize(text; fg = fg, bg = bg, opts = opts)

const NOCOLOR_PALETTE = "nocolor"
const DARK_PALETTE = "dark"
const LIGHT_PALETTE = "light"
const DEFAULT_PALETTE = DARK_PALETTE
const PALETTE_ROLES = ("ERROR", "SUCCESS", "WARNING", "NOTICE", "SQL_FIELD", "SQL_COLTYPE", "SQL_KEYWORD", "SQL_TABLE",
                       "HTTP_INFO", "HTTP_SUCCESS", "HTTP_REDIRECT", "HTTP_NOT_MODIFIED", "HTTP_BAD_REQUEST", "HTTP_NOT_FOUND",
                       "HTTP_SERVER_ERROR", "MIGRATE_HEADING", "MIGRATE_LABEL", "COMMAND_HEADER", "COMMAND_DATA", "COMMAND_HIGHLIGHT")
_pal(; fg = nothing, bg = nothing, opts = ()) = (d = Dict{String,Any}(); fg === nothing || (d["fg"] = fg);
                                                 bg === nothing || (d["bg"] = bg); isempty(opts) || (d["opts"] = opts); d)
"The named palettes: role => (\"fg\", \"bg\", \"opts\"), as Django's termcolors.PALETTES."
const PALETTES = Dict{String,Dict{String,Dict{String,Any}}}(
    NOCOLOR_PALETTE => Dict(r => Dict{String,Any}() for r in PALETTE_ROLES),
    DARK_PALETTE => Dict("ERROR" => _pal(fg = "red", opts = ("bold",)), "SUCCESS" => _pal(fg = "green", opts = ("bold",)),
        "WARNING" => _pal(fg = "yellow", opts = ("bold",)), "NOTICE" => _pal(fg = "red"), "SQL_FIELD" => _pal(fg = "green", opts = ("bold",)),
        "SQL_COLTYPE" => _pal(fg = "green"), "SQL_KEYWORD" => _pal(fg = "yellow"), "SQL_TABLE" => _pal(opts = ("bold",)),
        "HTTP_INFO" => _pal(opts = ("bold",)), "HTTP_SUCCESS" => _pal(), "HTTP_REDIRECT" => _pal(fg = "green"),
        "HTTP_NOT_MODIFIED" => _pal(fg = "cyan"), "HTTP_BAD_REQUEST" => _pal(fg = "red", opts = ("bold",)),
        "HTTP_NOT_FOUND" => _pal(fg = "yellow"), "HTTP_SERVER_ERROR" => _pal(fg = "magenta", opts = ("bold",)),
        "MIGRATE_HEADING" => _pal(fg = "cyan", opts = ("bold",)), "MIGRATE_LABEL" => _pal(opts = ("bold",)),
        "COMMAND_HEADER" => _pal(fg = "cyan", opts = ("bold",)), "COMMAND_DATA" => _pal(opts = ("bold",)),
        "COMMAND_HIGHLIGHT" => _pal(fg = "yellow", opts = ("bold",))),
    LIGHT_PALETTE => Dict("ERROR" => _pal(fg = "red", opts = ("bold",)), "SUCCESS" => _pal(fg = "green", opts = ("bold",)),
        "WARNING" => _pal(fg = "yellow", opts = ("bold",)), "NOTICE" => _pal(fg = "red"), "SQL_FIELD" => _pal(fg = "green", opts = ("bold",)),
        "SQL_COLTYPE" => _pal(fg = "green"), "SQL_KEYWORD" => _pal(fg = "blue"), "SQL_TABLE" => _pal(opts = ("bold",)),
        "HTTP_INFO" => _pal(opts = ("bold",)), "HTTP_SUCCESS" => _pal(), "HTTP_REDIRECT" => _pal(fg = "green", opts = ("bold",)),
        "HTTP_NOT_MODIFIED" => _pal(fg = "green"), "HTTP_BAD_REQUEST" => _pal(fg = "red", opts = ("bold",)),
        "HTTP_NOT_FOUND" => _pal(fg = "red"), "HTTP_SERVER_ERROR" => _pal(fg = "magenta", opts = ("bold",)),
        "MIGRATE_HEADING" => _pal(fg = "cyan", opts = ("bold",)), "MIGRATE_LABEL" => _pal(opts = ("bold",)),
        "COMMAND_HEADER" => _pal(fg = "cyan", opts = ("bold",)), "COMMAND_DATA" => _pal(opts = ("bold",)),
        "COMMAND_HIGHLIGHT" => _pal(fg = "yellow", opts = ("bold",))))

"""
    parse_color_setting(config) -> palette or nothing

A palette from a JUANGO_COLORS value, `"palette;role=fg/bg,option,option;..."` (Django's
DJANGO_COLORS): a named palette (light, dark, nocolor) then roles that change it. `""` is the default
palette; `nothing` when it sets no colors at all.
"""
function parse_color_setting(config::AbstractString)
    isempty(config) && return PALETTES[DEFAULT_PALETTE]
    palette = copy(PALETTES[NOCOLOR_PALETTE])
    for part in split(lowercase(config), ';')
        if haskey(PALETTES, part)
            merge!(palette, PALETTES[part])
        elseif occursin('=', part)
            pieces = split(part, '=')
            length(pieces) == 2 || continue
            role, instructions = uppercase(pieces[1]), pieces[2]
            styles = reverse(split(instructions, ','))
            colors = reverse(split(pop!(styles), '/'))
            definition = Dict{String,Any}()
            fg = pop!(colors)
            fg in TERM_COLOR_NAMES && (definition["fg"] = String(fg))
            !isempty(colors) && colors[end] in TERM_COLOR_NAMES && (definition["bg"] = String(colors[end]))
            opts = Tuple(String(s) for s in styles if haskey(TERM_OPTS, s))
            isempty(opts) || (definition["opts"] = opts)
            haskey(PALETTES[NOCOLOR_PALETTE], role) && !isempty(definition) && (palette[role] = definition)
        end
    end
    palette == PALETTES[NOCOLOR_PALETTE] ? nothing : palette
end

"""
A style: one function per palette role, `style.ERROR("text")` (Django's management.color.Style).
"""
struct Style
    roles::Dict{String,Function}
end
function Base.getproperty(s::Style, name::Symbol)
    name === :roles && return getfield(s, :roles)
    r = getfield(s, :roles)
    haskey(r, string(name)) || throw(ArgumentError("no style role $name"))
    r[string(name)]
end

"""
    make_style(config = "") -> Style

The style a JUANGO_COLORS value describes (`""`: the default palette), as Django's.
"""
function make_style(config::AbstractString = "")
    settings_ = parse_color_setting(config)
    roles = Dict{String,Function}()
    for role in PALETTE_ROLES
        if settings_ === nothing
            roles[role] = identity
        else
            f = get(settings_, role, Dict{String,Any}())
            roles[role] = termcolor_style(; fg = get(f, "fg", nothing), bg = get(f, "bg", nothing), opts = get(f, "opts", ()))
        end
    end
    roles["ERROR_OUTPUT"] = roles["ERROR"]
    Style(roles)
end
const NO_STYLE = Ref{Union{Nothing,Style}}(nothing)
"The style without colors."
no_style() = (s = NO_STYLE[]; s === nothing ? (NO_STYLE[] = make_style("nocolor")) : s)
"Whether `io` is a terminal that shows colors."
supports_color(io::IO = stdout) = io isa Base.TTY || (io isa IOContext && get(io, :color, false) === true)
"""
    color_style(; force_color = false, io = stdout) -> Style

The colors of JUANGO_COLORS (or DJANGO_COLORS) when `io` is a terminal or `force_color`, else none.
"""
color_style(; force_color::Bool = false, io::IO = stdout) =
    !force_color && !supports_color(io) ? no_style() : make_style(get(ENV, "JUANGO_COLORS", get(ENV, "DJANGO_COLORS", "")))
