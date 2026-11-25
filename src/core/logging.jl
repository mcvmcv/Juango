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

"""
Emails records to ADMINS, as Django's AdminEmailHandler: the subject is the level, whether the request came from
an INTERNAL_IPS address, and the message (newlines escaped, at most 989 characters); the body adds the request
and the traceback. `"include_html" => true` attaches the debug page as HTML.
"""
struct MailAdminsHandler <: LogHandler
    include_html::Bool
end
MailAdminsHandler() = MailAdminsHandler(false)
"A log subject on one line, as Django's format_subject."
format_log_subject(s) = (t = replace(string(s), "\n" => "\\n", "\r" => "\\r"); length(t) > 989 ? first(t, 989) : t)
function emit(h::MailAdminsHandler, r::LogRecord, fmt)
    req = get(r.data, :request, nothing)
    subject = req isa Request ?
        "$(level_name(r.level)) ($(get(req.meta, :remote_addr, "") in string.(something(get(settings, :INTERNAL_IPS, String[]), String[])) ? "internal" : "EXTERNAL") IP): $(r.message)" :
        "$(level_name(r.level)): $(r.message)"
    body = (req isa Request ? "$(req.method) $(full_path(req))\n\n" : "") * r.message
    if r.exception isa Tuple && req isa Request         # a view's exception: the debug page's report, as text
        body *= "\n\n" * exception_report_text(req, r.exception[1], r.exception[2]; chain = [r.exception])
    elseif r.exception !== nothing
        body *= "\n\n" * exception_text(r)
    end
    html = h.include_html && r.exception isa Tuple && req isa Request ? text(technical_500(req, r.exception[1], r.exception[2])) : nothing
    mail_admins(format_log_subject(subject), body; html_message = html, fail_silently = true)
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
    filters::Dict{String,Any}         # LOGGING's "filters": name => a function of the record (Django's CallbackFilter)
end
LoggingConfig(handlers, loggers, root, filters = Dict{String,Any}()) = LoggingConfig(handlers, loggers, root, Dict{String,Int}(), ReentrantLock(), filters)

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
    c == "file" ? FileHandler(d["filename"]) : c == "mail_admins" ? MailAdminsHandler(get(d, "include_html", false) === true) :
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
    # filters: a function of the record (true: keep it), or Dict("callback" => f) as Django's CallbackFilter config
    fs = Dict{String,Any}()
    for (n, f) in pairs(get(conf, "filters", Dict()))
        fs[string(n)] = f isa AbstractDict ? get(f, "callback", get(f, :callback, nothing)) : f
        fs[string(n)] isa Function || fs[string(n)] === nothing ||
            throw(ImproperlyConfigured("LOGGING: filter '$n' must be a function of the record, or Dict(\"callback\" => f)"))
    end
    LoggingConfig(hs, Dict(string(n) => lc(d) for (n, d) in pairs(get(conf, "loggers", Dict()))),
                  lc(merge(Dict("level" => "WARNING"), get(conf, "root", Dict()))), fs)
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

passes(h::HandlerConf, r::LogRecord, filters = Dict{String,Any}()) =
    r.level >= h.level && all(h.filters) do f
        f == "require_debug_false" ? !settings.DEBUG : f == "require_debug_true" ? settings.DEBUG :
        (cb = get(filters, f, nothing); cb === nothing || cb(r) == true)
    end

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
            passes(h, r, cfg.filters) || continue
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

# --- log_response (Django's django.utils.log.log_response) -------------------------------------------------

"""
A string as Python's unicode_escape writes it (Django escapes what it logs from a request): control characters
as `\\n`, `\\x1b`, ..., a backslash doubled, non-ASCII as `\\xe9`, `\\u0301`, `\\U0001f642`, so a log line
stays one line and a path can't forge one.
"""
function escape_log(s::AbstractString)
    io = IOBuffer()
    for c in s
        if !isvalid(c)              # (bytes that aren't UTF-8, from a percent-encoded path: each as \\xNN)
            foreach(b -> print(io, "\\x", string(b; base = 16, pad = 2)), codeunits(string(c)))
            continue
        end
        u = UInt32(c)
        if c == '\\'
            print(io, "\\\\")
        elseif c == '\n'
            print(io, "\\n")
        elseif c == '\r'
            print(io, "\\r")
        elseif c == '\t'
            print(io, "\\t")
        elseif u < 0x20 || 0x7f <= u <= 0xff
            print(io, "\\x", string(u; base = 16, pad = 2))
        elseif u > 0xff
            print(io, u <= 0xffff ? "\\u" * string(u; base = 16, pad = 4) : "\\U" * string(u; base = 16, pad = 8))
        else
            print(io, c)
        end
    end
    String(take!(io))
end
escape_log(x) = string(x)

"Responses already logged (an exception's response is logged where it's made, with the exception)."
const LOGGED_RESPONSES = WeakKeyDict{Any,Bool}()
const LOGGED_RESPONSES_LOCK = ReentrantLock()
mark_logged!(r) = (r === nothing || lock(() -> (LOGGED_RESPONSES[r] = true), LOGGED_RESPONSES_LOCK); r)
was_logged(r) = lock(() -> haskey(LOGGED_RESPONSES, r), LOGGED_RESPONSES_LOCK)

"""
    log_response(message, args...; response, request = nothing, logger = "juango.request", level = nothing, exception = nothing)

Log a response once, as Django's: 5xx as errors, 4xx as warnings, others as info (unless `level`), with its
`status_code` and the request; `%s`/`%d` in `message` take `args`, strings escaped (`escape_log`).
"""
function log_response(message, args...; response, request = nothing, logger = "juango.request", level = nothing, exception = nothing)
    response === nothing && throw(ArgumentError("log_response needs a response"))
    was_logged(response) && return nothing
    st = response.status
    lvl = level !== nothing ? level : st >= 500 ? :error : st >= 400 ? :warning : :info
    it = Iterators.Stateful(args)
    msg = replace(string(message), r"%[sd]" => _ -> (isempty(it) ? "" : escape_log(popfirst!(it))))
    log!(logger, lvl, msg; exception = exception, request = request, status_code = st)
    mark_logged!(response)
    nothing
end

"HTTP reason phrases (Python's http.HTTPStatus, as Django's response.reason_phrase)."
const REASON_PHRASES = Dict(100 => "Continue", 101 => "Switching Protocols", 200 => "OK", 201 => "Created", 202 => "Accepted",
    204 => "No Content", 206 => "Partial Content", 301 => "Moved Permanently", 302 => "Found", 303 => "See Other",
    304 => "Not Modified", 307 => "Temporary Redirect", 308 => "Permanent Redirect", 400 => "Bad Request", 401 => "Unauthorized",
    402 => "Payment Required", 403 => "Forbidden", 404 => "Not Found", 405 => "Method Not Allowed", 406 => "Not Acceptable",
    408 => "Request Timeout", 409 => "Conflict", 410 => "Gone", 411 => "Length Required", 412 => "Precondition Failed",
    413 => "Request Entity Too Large", 414 => "Request-URI Too Long", 415 => "Unsupported Media Type",
    416 => "Requested Range Not Satisfiable", 417 => "Expectation Failed", 418 => "I'm a Teapot", 421 => "Misdirected Request",
    422 => "Unprocessable Entity", 423 => "Locked", 424 => "Failed Dependency", 425 => "Too Early", 426 => "Upgrade Required",
    428 => "Precondition Required", 429 => "Too Many Requests", 431 => "Request Header Fields Too Large",
    451 => "Unavailable For Legal Reasons", 500 => "Internal Server Error", 501 => "Not Implemented", 502 => "Bad Gateway",
    503 => "Service Unavailable", 504 => "Gateway Timeout", 505 => "HTTP Version Not Supported", 506 => "Variant Also Negotiates",
    507 => "Insufficient Storage", 508 => "Loop Detected", 510 => "Not Extended", 511 => "Network Authentication Required")
"A status code's reason phrase (\"Unknown Status Code\" for one HTTP doesn't name, as Django's)."
reason_phrase(status::Integer) = get(REASON_PHRASES, Int(status), "Unknown Status Code")
