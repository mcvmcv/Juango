# Time zones -----------------------------------------------------------------------------------------------
#
#     configure!(USE_TZ = true, TIME_ZONE = "Europe/Berlin")
#
# With USE_TZ, DateTimeField values are aware `ZonedDateTime`s, stored in UTC (TIMESTAMP WITH
# TIME ZONE on PostgreSQL, UTC text/DATETIME elsewhere) and shown in the *current* time zone:
# the one activated for the request (`activate_timezone!`, `TimezoneMiddleware`), else TIME_ZONE.
# Naive DateTimes given to the ORM are taken to be in the current time zone.
#
#     {% timezone "Asia/Tokyo" %}{{ event.start }}{% endtimezone %}   {{ event.start|utc }}
#     manage.jl convert_naive_datetimes        # existing naive data -> UTC, when switching USE_TZ on

const UTC_TZ = TimeZones.tz"UTC"

"The time zone named by TIME_ZONE."
default_timezone() = TimeZones.TimeZone(string(settings.TIME_ZONE))
"The current time zone: activated for this task, else TIME_ZONE."
function get_current_timezone()
    tz = get(task_local_storage(), :juango_timezone, nothing)
    tz === nothing ? default_timezone() : tz
end
"Make a time zone (or its name) current for this task, e.g. for a user's preference."
activate_timezone!(tz) = (task_local_storage(:juango_timezone, tz isa TimeZones.TimeZone ? tz : TimeZones.TimeZone(string(tz))); nothing)
"Back to TIME_ZONE."
deactivate_timezone!() = (delete!(task_local_storage(), :juango_timezone); nothing)
"Run `f()` with a time zone current."
function with_timezone(f, tz)
    old = get(task_local_storage(), :juango_timezone, nothing)
    activate_timezone!(tz)
    try
        f()
    finally
        old === nothing ? deactivate_timezone!() : task_local_storage(:juango_timezone, old)
    end
end

"""
    timezone_now() -> ZonedDateTime (USE_TZ) or DateTime

The current time: aware and in UTC with USE_TZ, naive local time otherwise. `auto_now`
fields use it.
"""
timezone_now() = settings.USE_TZ ? TimeZones.now(UTC_TZ) : now()

"Attach the current (or given) time zone to a naive DateTime."
make_aware(dt::DateTime, tz = get_current_timezone()) = TimeZones.ZonedDateTime(dt, tz; from_utc = false)
make_aware(z::TimeZones.ZonedDateTime, tz = nothing) = z
"Local wall-clock time of an aware datetime in the current (or given) time zone, as a naive DateTime."
make_naive(z::TimeZones.ZonedDateTime, tz = get_current_timezone()) = DateTime(TimeZones.astimezone(z, tz))
"An aware datetime in the current (or given) time zone."
localtime(z::TimeZones.ZonedDateTime, tz = get_current_timezone()) = TimeZones.astimezone(z, tz)
localtime(x, tz = nothing) = x
is_aware(x) = x isa TimeZones.ZonedDateTime

# --- the ORM: store UTC, return aware values ---------------------------------------------------------------------

"A datetime as stored: naive UTC (aware values converted; naive ones taken as current-time-zone local)."
function to_utc_naive(v)
    v isa TimeZones.ZonedDateTime && return DateTime(TimeZones.astimezone(v, UTC_TZ))
    v isa DateTime && settings.USE_TZ && return DateTime(TimeZones.astimezone(make_aware(v), UTC_TZ))
    v
end
"A datetime read from the database (USE_TZ: aware, in UTC)."
function datetime_from_db(v)
    settings.USE_TZ || return v isa TimeZones.ZonedDateTime ? DateTime(TimeZones.astimezone(v, default_timezone())) : v
    v isa TimeZones.ZonedDateTime && return TimeZones.astimezone(v, UTC_TZ)
    v isa DateTime ? TimeZones.ZonedDateTime(v, UTC_TZ) : v
end
adapt_param(::DatabaseBackend, z::TimeZones.ZonedDateTime) = DateTime(TimeZones.astimezone(z, UTC_TZ))
adapt_param(b::SQLiteBackend, z::TimeZones.ZonedDateTime) = adapt_param(b, DateTime(TimeZones.astimezone(z, UTC_TZ)))

# --- templates ---------------------------------------------------------------------------------------------------

todatetime(z::TimeZones.ZonedDateTime) = local_wall_clock(z)
local_wall_clock(z) = get(task_local_storage(), :juango_localtime_off, false) ? DateTime(z) : make_naive(z)
display_string(z::TimeZones.ZonedDateTime) = format_date(z, get_format().datetime)
json_scalar(z::TimeZones.ZonedDateTime) = string(TimeZones.astimezone(z, UTC_TZ))

"`{% timezone \"Europe/Paris\" %}...{% endtimezone %}` (or a variable; `None` for TIME_ZONE)."
struct TimezoneNode <: Node
    tz::Any
    nodes::Vector{Node}
end
child_nodelists(n::TimezoneNode) = (n.nodes,)
tag_timezone(p::Parser, t::Token) = TimezoneNode(parse_filter_expr(split_contents(t.contents)[2]), first(parse_nodes(p, ["endtimezone"])))
function render!(io::IO, n::TimezoneNode, ctx::Context)
    tz = eval_fe(n.tz, ctx)
    tz === nothing && return write(io, with_timezone(() -> render_nodes(n.nodes, ctx), default_timezone()))
    write(io, with_timezone(() -> render_nodes(n.nodes, ctx), tz))
end

"`{% localtime off %}...{% endlocaltime %}`: show aware datetimes in their own zone (UTC from the database)."
struct LocaltimeNode <: Node
    on::Bool
    nodes::Vector{Node}
end
child_nodelists(n::LocaltimeNode) = (n.nodes,)
function tag_localtime(p::Parser, t::Token)
    bits = split_contents(t.contents)
    LocaltimeNode(length(bits) < 2 || bits[2] != "off", first(parse_nodes(p, ["endlocaltime"])))
end
function render!(io::IO, n::LocaltimeNode, ctx::Context)
    old = get(task_local_storage(), :juango_localtime_off, false)
    task_local_storage(:juango_localtime_off, !n.on)
    try
        render_nodes(io, n.nodes, ctx)
    finally
        task_local_storage(:juango_localtime_off, old)
    end
end

register_tag!("timezone", tag_timezone)
register_tag!("localtime", tag_localtime)
"An aware datetime pinned to a zone by the `utc`/`timezone`/`localtime` filters (not converted again)."
struct PinnedTime
    z::TimeZones.ZonedDateTime
end
todatetime(p::PinnedTime) = DateTime(p.z)
display_string(p::PinnedTime) = format_date(p, get_format().datetime)
pin(v, tz) = v isa TimeZones.ZonedDateTime ? PinnedTime(TimeZones.astimezone(v, tz)) : v isa PinnedTime ? PinnedTime(TimeZones.astimezone(v.z, tz)) : v
register_filter!("localtime", (v, _) -> pin(v, get_current_timezone()))
register_filter!("utc", (v, _) -> pin(v, UTC_TZ))
register_filter!("timezone", (v, a) -> pin(v, TimeZones.TimeZone(string(a))))

"""
Activates the time zone stored in the session under `\"juango_timezone\"` (set it from a
user's preference); otherwise TIME_ZONE applies.
"""
function TimezoneMiddleware(get_response)
    function (req::Request)
        name = req.session isa Session ? get(req.session, "juango_timezone", nothing) : nothing
        name === nothing && return get_response(req)
        tz = try
            TimeZones.TimeZone(string(name))
        catch
            return get_response(req)
        end
        with_timezone(() -> get_response(req), tz)
    end
end

# --- moving existing naive data to UTC ------------------------------------------------------------------------------

"""
    convert_naive_datetimes(; from_tz=TIME_ZONE)

When switching USE_TZ on for an existing database: reinterpret every stored DateTimeField
value as wall-clock time in `from_tz` and rewrite it as UTC (on PostgreSQL the columns also
become TIMESTAMP WITH TIME ZONE). Run it once, after backing up.
"""
function convert_naive_datetimes(; from_tz = settings.TIME_ZONE, verbose = true)
    tz = TimeZones.TimeZone(string(from_tz))
    b = backend()
    n = 0
    atomic() do
        for T in all_models()
            m = modelmeta(T)
            m.proxy && continue
            for f in m.fields
                f.kind === :datetime || continue
                t, c = quote_name(b, m.table), quote_name(b, column(f))
                if b isa PostgresBackend
                    execute("ALTER TABLE $t ALTER COLUMN $c TYPE TIMESTAMP WITH TIME ZONE USING $c AT TIME ZONE '$(replace(string(tz), "'" => "''"))'")
                    n += 1
                    continue
                end
                for r in execute("SELECT $(quote_name(b, "id")) AS id, $c AS v FROM $t WHERE $c IS NOT NULL")
                    v = r[:v] isa DateTime ? r[:v] : something(todatetime(string(r[:v])), nothing)
                    v === nothing && continue
                    utc = DateTime(TimeZones.astimezone(TimeZones.ZonedDateTime(v, tz; from_utc = false), UTC_TZ))
                    execute("UPDATE $t SET $c = ? WHERE $(quote_name(b, "id")) = ?", Any[utc, r[:id]])
                end
                n += 1
                verbose && println("  converted $(m.table).$(column(f))")
            end
        end
    end
    n
end
