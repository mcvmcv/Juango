# Logging --------------------------------------------------------------------------------------------
#
# Named loggers in a hierarchy ("juango.db.backends" passes its records up to "juango", then the
# root), configured by the LOGGING setting in the shape of Django's dictConfig:
#
#     configure!(LOGGING = Dict(
#         "handlers" => Dict(
#             "console" => Dict("class" => "console", "level" => "INFO", "format" => "{levelname} {name}: {message}"),
#             "file" => Dict("class" => "file", "filename" => "site.log", "level" => "WARNING"),
#             "mail_admins" => Dict("class" => "mail_admins", "level" => "ERROR", "filters" => ["require_debug_false"])),
#         "loggers" => Dict(
#             "juango.request" => Dict("handlers" => ["mail_admins", "file"], "level" => "WARNING", "propagate" => false),
#             "juango.db.backends" => Dict("handlers" => ["console"], "level" => "DEBUG")),   # every SQL statement
#         "root" => Dict("handlers" => ["console"], "level" => "WARNING")))
#
# Handler classes: "julia" (Julia's logging, so @info-style output and your logger of choice),
# "console" (stderr, or "stream" => io), "file", "mail_admins", "memory" (keeps records; for
# tests), or a handler value of your own (`emit(handler, record)`). Juango logs to:
#   juango.request      5xx errors (ERROR, with the exception) and 4xx responses (WARNING)
#   juango.db.backends  each SQL statement and its duration (DEBUG)
#   juango.security     CSRF failures and disallowed hosts (WARNING)
#
#     log!("myapp.payments", :info, "charged"; amount = 10)
#
# Without LOGGING, errors go to Julia's logger, and 500 errors are mailed to ADMINS when DEBUG
# is false.

const LOG_LEVELS = Dict("DEBUG" => 10, "INFO" => 20, "WARNING" => 30, "ERROR" => 40, "CRITICAL" => 50)
log_level(l::Integer) = Int(l)
log_level(l) = LOG_LEVELS[uppercase(string(l))]
level_name(n::Integer) = something(findfirst(==(n), LOG_LEVELS), "LEVEL $n")

"A log record: logger name, level, message, time, extra data and an optional `(exception, backtrace)`."
struct LogRecord
    name::String
    level::Int
    message::String
    time::DateTime
    data::Dict{Symbol,Any}
    exception::Any
end

abstract type LogHandler end
"Write a record (define for your own handler types)."
function emit end

mutable struct HandlerConf
    handler::Any
    level::Int
    filters::Vector{String}
    format::String
end

const DEFAULT_LOG_FORMAT = "[{asctime}] {levelname} {name}: {message}"

function format_record(fmt::AbstractString, r::LogRecord)
    s = replace(fmt, "{asctime}" => Dates.format(r.time, "yyyy-mm-dd HH:MM:SS"), "{levelname}" => level_name(r.level),
                "{name}" => r.name, "{message}" => r.message)
    for (k, v) in r.data
        s = replace(s, "{$k}" => string(v))
    end
    s
end
exception_text(r::LogRecord) = r.exception === nothing ? "" :
    (r.exception isa Tuple ? sprint(showerror, r.exception[1], r.exception[2]) : sprint(showerror, r.exception))

"Records of WARNING and up (or the configured level) to Julia's current logger."
struct JuliaHandler <: LogHandler end
function emit(::JuliaHandler, r::LogRecord, fmt)
    lvl = r.level >= 40 ? Base.CoreLogging.Error : r.level >= 30 ? Base.CoreLogging.Warn :
          r.level >= 20 ? Base.CoreLogging.Info : Base.CoreLogging.Debug
    data = Dict(k => v for (k, v) in r.data if k !== :request)
    if r.exception === nothing
        isempty(data) ? (Base.CoreLogging.@logmsg lvl r.message _group = Symbol(r.name)) : (Base.CoreLogging.@logmsg lvl r.message _group = Symbol(r.name) data)
    else
        Base.CoreLogging.@logmsg lvl r.message _group = Symbol(r.name) exception = r.exception
    end
end

"Writes formatted records to a stream (stderr by default)."
struct StreamHandler <: LogHandler
    io::IO
end
function emit(h::StreamHandler, r::LogRecord, fmt)
    println(h.io, format_record(fmt, r))
    r.exception === nothing || println(h.io, exception_text(r))
    flush(h.io)
end

"Appends formatted records to a file."
struct FileHandler <: LogHandler
    filename::String
    lock::ReentrantLock
end
FileHandler(f) = FileHandler(string(f), ReentrantLock())
function emit(h::FileHandler, r::LogRecord, fmt)
    lock(h.lock) do
        open(h.filename, "a") do io
            println(io, format_record(fmt, r))
            r.exception === nothing || println(io, exception_text(r))
        end
    end
end

"Emails records to ADMINS (the subject is the level and message; the body adds the request and traceback)."
struct MailAdminsHandler <: LogHandler end
function emit(::MailAdminsHandler, r::LogRecord, fmt)
    req = get(r.data, :request, nothing)
    body = (req isa Request ? "$(req.method) $(full_path(req))\n\n" : "") * r.message
    r.exception === nothing || (body *= "\n\n" * exception_text(r))
    mail_admins(level_name(r.level) * ": " * first(split(r.message, '\n')), body; fail_silently = true)
end

"Keeps the records it gets (`handler.records`); useful in tests."
struct MemoryHandler <: LogHandler
    records::Vector{LogRecord}
end
MemoryHandler() = MemoryHandler(LogRecord[])
emit(h::MemoryHandler, r::LogRecord, fmt) = push!(h.records, r)

struct LoggerConf
    handlers::Vector{String}
    level::Union{Nothing,Int}
    propagate::Bool
end

struct LoggingConfig
    handlers::Dict{String,HandlerConf}
    loggers::Dict{String,LoggerConf}
    root::LoggerConf
    levels::Dict{String,Int}          # effective level per logger name, filled in on first use
    lock::ReentrantLock
end
LoggingConfig(handlers, loggers, root) = LoggingConfig(handlers, loggers, root, Dict{String,Int}(), ReentrantLock())

default_logging() = Dict(
    "handlers" => Dict("julia" => Dict("class" => "julia", "level" => "ERROR"),
                       "mail_admins" => Dict("class" => "mail_admins", "level" => "ERROR", "filters" => ["require_debug_false"])),
    "loggers" => Dict("juango.request" => Dict("handlers" => ["mail_admins"], "level" => "WARNING", "propagate" => true)),
    "root" => Dict("handlers" => ["julia"], "level" => "WARNING"))

function make_handler(d)
    d isa AbstractDict || return d                       # a handler value
    c = get(d, "class", "console")
    c isa AbstractString || return c
    c == "julia" ? JuliaHandler() : c == "console" ? StreamHandler(get(d, "stream", stderr)) :
    c == "file" ? FileHandler(d["filename"]) : c == "mail_admins" ? MailAdminsHandler() :
    c == "memory" ? MemoryHandler() : throw(ImproperlyConfigured("LOGGING: unknown handler class '$c'"))
end

function parse_logging(conf)
    hs = Dict{String,HandlerConf}()
    for (n, d) in pairs(get(conf, "handlers", Dict()))
        dd = d isa AbstractDict ? d : Dict("class" => d)
        hs[string(n)] = HandlerConf(make_handler(dd), log_level(get(dd, "level", 0)),
                                    String[string(f) for f in get(dd, "filters", String[])], string(get(dd, "format", DEFAULT_LOG_FORMAT)))
    end
    lc(d) = LoggerConf(String[string(h) for h in get(d, "handlers", String[])],
                       haskey(d, "level") ? log_level(d["level"]) : nothing, get(d, "propagate", true))
    for d in vcat([get(conf, "root", Dict())], collect(values(get(conf, "loggers", Dict()))))
        for h in get(d, "handlers", String[])
            haskey(hs, string(h)) || throw(ImproperlyConfigured("LOGGING: no handler named '$h'"))
        end
    end
    LoggingConfig(hs, Dict(string(n) => lc(d) for (n, d) in pairs(get(conf, "loggers", Dict()))),
                  lc(merge(Dict("level" => "WARNING"), get(conf, "root", Dict()))))
end

const LOGGING_CONFIG = Ref{Union{Nothing,LoggingConfig}}(nothing)
const LOGGING_LOCK = ReentrantLock()
push!(SETTINGS_CHANGED_HOOKS, () -> lock(() -> (LOGGING_CONFIG[] = nothing), LOGGING_LOCK))
function logging_config()
    c = LOGGING_CONFIG[]
    c === nothing || return c
    lock(LOGGING_LOCK) do
        LOGGING_CONFIG[] === nothing && (LOGGING_CONFIG[] = parse_logging(something(get(settings, :LOGGING, nothing), default_logging())))
        LOGGING_CONFIG[]
    end
end

"The logger chain of a name: \"a.b.c\", \"a.b\", \"a\" (only configured ones), then the root."
function logger_chain(cfg::LoggingConfig, name::AbstractString)
    out = LoggerConf[]
    parts = split(name, '.')
    for i in length(parts):-1:1
        c = get(cfg.loggers, join(parts[1:i], '.'), nothing)
        c === nothing || push!(out, c)
    end
    push!(out, cfg.root)
    out
end

"The level a logger lets through: its own, or its nearest configured ancestor's (memoized: checked for every SQL statement)."
function effective_level(cfg::LoggingConfig, name::AbstractString)
    lock(cfg.lock) do
        get!(cfg.levels, name) do
            for c in logger_chain(cfg, name)
                c.level === nothing || return c.level
            end
            30
        end
    end
end

"Whether a record of `level` from logger `name` would be handled (to skip building costly messages)."
log_enabled(name::AbstractString, level) = log_level(level) >= effective_level(logging_config(), name)

passes(h::HandlerConf, r::LogRecord) =
    r.level >= h.level && all(f -> f == "require_debug_false" ? !settings.DEBUG : f == "require_debug_true" ? settings.DEBUG : true, h.filters)

"""
    log!(name, level, message; exception = nothing, data...)

Log a record from logger `name` (`:debug`, `:info`, `:warning`, `:error`, `:critical`, or a
number) to the handlers LOGGING gives it and its ancestors (until one has `propagate = false`).
"""
function log!(name::AbstractString, level, message; exception = nothing, kw...)
    cfg = logging_config()
    lvl = log_level(level)
    lvl >= effective_level(cfg, name) || return nothing
    r = LogRecord(string(name), lvl, string(message), now(), Dict{Symbol,Any}(kw), exception)
    for c in logger_chain(cfg, name)
        for hn in c.handlers
            h = cfg.handlers[hn]
            passes(h, r) || continue
            try
                emit(h.handler, r, h.format)
            catch e
                @error "Logging handler '$hn' failed" exception = e
            end
        end
        c.propagate || break
    end
    nothing
end
