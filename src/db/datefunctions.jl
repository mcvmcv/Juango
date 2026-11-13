# Date and time functions and lookups ------------------------------------------------------------------
#
#     filter(Post; created__year = 2026, created__hour__gte = 9)       # transforms chain
#     filter(Post; created__date = Date(2026, 3, 1), created__week_day = 2)
#     annotate(Post; month = TruncMonth(:created)) |> values(:month) |> annotate(n = Count(:id))
#     annotate(Post; q = ExtractQuarter(:created))
#
# With USE_TZ, datetimes are converted to the current time zone first, as in Django. PostgreSQL
# does it with AT TIME ZONE, MySQL/MariaDB with CONVERT_TZ (which needs the server's time zone
# tables), and SQLite through two functions Juango registers on its connections.

"Date transforms: name => (kinds they apply to, result kind)."
const DATE_TRANSFORMS = Dict(
    "year" => ((:date, :datetime), :int), "quarter" => ((:date, :datetime), :int),
    "month" => ((:date, :datetime), :int), "week" => ((:date, :datetime), :int),
    "week_day" => ((:date, :datetime), :int), "iso_week_day" => ((:date, :datetime), :int),
    "iso_year" => ((:date, :datetime), :int), "day" => ((:date, :datetime), :int),
    "hour" => ((:datetime, :time), :int), "minute" => ((:datetime, :time), :int),
    "second" => ((:datetime, :time), :int), "date" => ((:datetime,), :date), "time" => ((:datetime,), :time))
const TRUNC_KINDS = (:year, :quarter, :month, :week, :day, :hour, :minute, :second, :date, :time)

"The time zone datetimes are shown in (nothing without USE_TZ)."
local_tz_name() = settings.USE_TZ ? string(TimeZones.name(get_current_timezone())) : nothing

"`(sql, kind)` for a built-in date transform of `col`, or nothing when it doesn't apply."
function date_transform(col, kind, name)
    t = get(DATE_TRANSFORMS, name, nothing)
    (t === nothing || !(kind in t[1])) && return nothing
    date_part_expr(backend(), Symbol(name), col, kind), t[2]
end

# --- SQL per backend ----------------------------------------------------------------------------------

"A datetime column as local time (PostgreSQL: AT TIME ZONE)."
# (the cast makes a naive UTC timestamp aware first; the session's time zone is UTC)
local_sql(::DatabaseBackend, col, kind) = (tz = local_tz_name(); kind === :datetime && tz !== nothing ?
    "(CAST($col AS TIMESTAMP WITH TIME ZONE) AT TIME ZONE '$tz')" : col)

"A part of a date, datetime or time expression, in local time (an integer, or a date or time)."
function date_part_expr(b::DatabaseBackend, part::Symbol, col, kind)
    x = local_sql(b, col, kind)
    part === :date && return "CAST($x AS DATE)"
    part === :time && return "CAST($x AS TIME)"
    part === :second && return "CAST(FLOOR(EXTRACT(SECOND FROM $x)) AS INTEGER)"
    part === :week_day && return "(CAST(EXTRACT(DOW FROM $x) AS INTEGER) + 1)"           # 1 = Sunday, as Django
    pg = Dict(:iso_week_day => "ISODOW", :iso_year => "ISOYEAR")
    "CAST(EXTRACT($(get(pg, part, uppercase(string(part)))) FROM $x) AS INTEGER)"
end

"A date or datetime truncated to `kind`; datetimes come back in UTC (aware) with USE_TZ."
function trunc_expr(b::DatabaseBackend, kind::Symbol, col, ink)
    x = local_sql(b, col, ink)
    kind === :date && return "CAST($x AS DATE)"
    kind === :time && return "CAST($x AS TIME)"
    t = "DATE_TRUNC('$kind', $x)"
    ink === :date && return "CAST($t AS DATE)"
    tz = local_tz_name()
    tz === nothing ? t : "($t AT TIME ZONE '$tz')"
end

function local_sql(::MySQLBackend, col, kind)
    tz = local_tz_name()
    kind === :datetime && tz !== nothing && tz != "UTC" ? "CONVERT_TZ($col, '+00:00', '$tz')" : col
end
function date_part_expr(b::MySQLBackend, part::Symbol, col, kind)
    x = local_sql(b, col, kind)
    part === :week && return "WEEK($x, 3)"                       # ISO weeks
    part === :week_day && return "DAYOFWEEK($x)"
    part === :iso_week_day && return "(WEEKDAY($x) + 1)"
    part === :iso_year && return "(YEARWEEK($x, 3) DIV 100)"
    "$(uppercase(string(part)))($x)"
end
function trunc_expr(b::MySQLBackend, kind::Symbol, col, ink)
    x = local_sql(b, col, ink)
    kind === :date && return "DATE($x)"
    kind === :time && return "TIME($x)"
    t = kind === :quarter ? "CAST(MAKEDATE(YEAR($x), 1) + INTERVAL (QUARTER($x) - 1) QUARTER AS DATETIME)" :
        kind === :week ? "CAST(DATE_SUB(DATE($x), INTERVAL WEEKDAY($x) DAY) AS DATETIME)" :
        "CAST(DATE_FORMAT($x, '" * Dict(:year => "%Y-01-01 00:00:00", :month => "%Y-%m-01 00:00:00", :day => "%Y-%m-%d 00:00:00",
                                        :hour => "%Y-%m-%d %H:00:00", :minute => "%Y-%m-%d %H:%i:00",
                                        :second => "%Y-%m-%d %H:%i:%s")[kind] * "') AS DATETIME)"
    ink === :date && return "DATE($t)"
    tz = local_tz_name()
    tz === nothing || tz == "UTC" ? t : "CONVERT_TZ($t, '$tz', '+00:00')"
end

tzarg(kind) = kind === :datetime ? something(local_tz_name(), "") : ""
date_part_expr(b::SQLiteBackend, part::Symbol, col, kind) = "juango_datepart('$part', $col, '$(tzarg(kind))')"
trunc_expr(b::SQLiteBackend, kind::Symbol, col, ink) = "juango_trunc('$kind', $col, '$(tzarg(ink))', '$ink')"

# --- SQLite: the functions behind juango_datepart / juango_trunc --------------------------------------

"A date, datetime or time value as SQLite returns it."
function sqlite_temporal(v)
    v isa Union{DateTime,Date,Dates.Time} && return v
    s = string(v)
    occursin(r"^\d{4}-\d{2}-\d{2}$", s) && return Date(s)
    occursin(r"^\d{1,2}:\d{2}", s) && return parse_time(s)
    something(todatetime(s), Some(nothing))
end
tz_local(dt::DateTime, tz) = isempty(tz) ? dt : DateTime(TimeZones.astimezone(TimeZones.ZonedDateTime(dt, TimeZones.tz"UTC"), TimeZones.TimeZone(tz)))
function tz_utc(dt::DateTime, tz)
    isempty(tz) && return dt
    z = try
        TimeZones.ZonedDateTime(dt, TimeZones.TimeZone(tz))
    catch e
        e isa TimeZones.AmbiguousTimeError ? TimeZones.ZonedDateTime(dt, TimeZones.TimeZone(tz), 1) :
        e isa TimeZones.NonExistentTimeError ? TimeZones.ZonedDateTime(dt + Dates.Hour(1), TimeZones.TimeZone(tz)) : rethrow()
    end
    DateTime(TimeZones.astimezone(z, TimeZones.tz"UTC"))
end
sqlite_datetime_text(dt::DateTime) = Dates.format(dt, "yyyy-mm-ddTHH:MM:SS.sss")

function sqlite_datepart(part::AbstractString, v, tz::AbstractString)
    (v === missing || v === nothing) && return missing
    t = sqlite_temporal(v)
    t === nothing && return missing
    t isa DateTime && (t = tz_local(t, tz))
    part == "date" && return string(Date(t))
    part == "time" && return time_string(Dates.Time(t))
    part == "hour" && return Dates.hour(t)
    part == "minute" && return Dates.minute(t)
    part == "second" && return Dates.second(t)
    d = Date(t)
    part == "year" && return Dates.year(d)
    part == "quarter" && return Dates.quarterofyear(d)
    part == "month" && return Dates.month(d)
    part == "day" && return Dates.day(d)
    part == "week" && return Dates.week(d)
    part == "week_day" && return mod(Dates.dayofweek(d), 7) + 1
    part == "iso_week_day" && return Dates.dayofweek(d)
    part == "iso_year" && return Dates.year(d + Dates.Day(4 - Dates.dayofweek(d)))
    missing
end

function sqlite_trunc(kind::AbstractString, v, tz::AbstractString, ink::AbstractString)
    (v === missing || v === nothing) && return missing
    t = sqlite_temporal(v)
    t === nothing && return missing
    t isa DateTime && (t = tz_local(t, tz))
    kind == "date" && return string(Date(t))
    kind == "time" && return time_string(Dates.Time(t))
    d = DateTime(t isa Date ? DateTime(t) : t)
    r = kind == "year" ? DateTime(Dates.year(d), 1, 1) : kind == "quarter" ? DateTime(Dates.firstdayofquarter(Date(d))) :
        kind == "month" ? DateTime(Dates.year(d), Dates.month(d), 1) : kind == "week" ? DateTime(Dates.firstdayofweek(Date(d))) :
        kind == "day" ? DateTime(Date(d)) : floor(d, kind == "hour" ? Dates.Hour : kind == "minute" ? Dates.Minute : Dates.Second)
    ink == "date" && return string(Date(r))
    sqlite_datetime_text(tz_utc(r, tz))
end

"Register Juango's date functions on a new SQLite connection."
function register_sqlite_functions!(db)
    SQLite.register(db, sqlite_datepart; nargs = 3, name = "juango_datepart")
    SQLite.register(db, sqlite_trunc; nargs = 4, name = "juango_trunc")
    db
end

# --- expressions: Extract* and Trunc* -----------------------------------------------------------------

"""
    Extract(expr, part)

A part of a date, datetime or time as an integer: `:year`, `:quarter`, `:month`, `:week` (ISO),
`:week_day` (1 = Sunday), `:iso_week_day` (1 = Monday), `:iso_year`, `:day`, `:hour`, `:minute`,
`:second`. Also `ExtractYear(:created)` and the like.
"""
function Extract(x, part)
    p = Symbol(part)
    haskey(DATE_TRANSFORMS, string(p)) && DATE_TRANSFORMS[string(p)][2] === :int ||
        throw(ArgumentError("Extract: unknown part :$p"))
    Func(:extract, Any[ref(x), p])
end
ExtractYear(x) = Extract(x, :year)
ExtractQuarter(x) = Extract(x, :quarter)
ExtractMonth(x) = Extract(x, :month)
ExtractWeek(x) = Extract(x, :week)
ExtractWeekDay(x) = Extract(x, :week_day)
ExtractIsoWeekDay(x) = Extract(x, :iso_week_day)
ExtractIsoYear(x) = Extract(x, :iso_year)
ExtractDay(x) = Extract(x, :day)
ExtractHour(x) = Extract(x, :hour)
ExtractMinute(x) = Extract(x, :minute)
ExtractSecond(x) = Extract(x, :second)

"""
    Trunc(expr, kind)

A date or datetime truncated to `:year`, `:quarter`, `:month`, `:week` (starting Monday), `:day`,
`:hour`, `:minute` or `:second` in the current time zone; `:date` and `:time` give the date or the
time of a datetime. Also `TruncMonth(:created)` and the like.
"""
function Trunc(x, kind)
    k = Symbol(kind)
    k in TRUNC_KINDS || throw(ArgumentError("Trunc: kind must be one of $(join(TRUNC_KINDS, ", "))"))
    Func(:trunc, Any[ref(x), k])
end
TruncYear(x) = Trunc(x, :year)
TruncQuarter(x) = Trunc(x, :quarter)
TruncMonth(x) = Trunc(x, :month)
TruncWeek(x) = Trunc(x, :week)
TruncDay(x) = Trunc(x, :day)
TruncDate(x) = Trunc(x, :date)
TruncTime(x) = Trunc(x, :time)
TruncHour(x) = Trunc(x, :hour)
TruncMinute(x) = Trunc(x, :minute)
TruncSecond(x) = Trunc(x, :second)

"The kind of value a `Trunc` gives for an input of kind `ink`."
trunc_output(kind, ink) = kind === :date ? :date : kind === :time ? :time : ink === :date ? :date : :datetime
