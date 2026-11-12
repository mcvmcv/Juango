# Admin change history ---------------------------------------------------------------------------------
#
# Every add, change and delete made in the admin is recorded as a LogEntry. Record your own
# with `log_action!(user, obj, CHANGE, "Published.")`.

@model struct LogEntry
    action_time = DateTimeField(auto_now_add = true)
    user = ForeignKey(USER_MODEL, null = true, on_delete = :SET_NULL)
    content_type = ForeignKey(ContentType, null = true, on_delete = :SET_NULL)
    object_id = TextField(null = true, blank = true)
    object_repr = CharField(max_length = 200)
    action_flag = IntegerField()
    change_message = TextField(blank = true)
    Meta(table = "juango_admin_log", app_label = "admin", ordering = ["-action_time", "-id"],
         verbose_name = "log entry", verbose_name_plural = "log entries")
end

# LogEntry action flags.
const ADDITION, CHANGE, DELETION = 1, 2, 3

"Record an admin action on `obj` by `user` (`ADDITION`, `CHANGE` or `DELETION`)."
function log_action!(user, obj::Model, flag::Integer, message::AbstractString = "")
    u = user isa AbstractUser ? user : nothing
    create(LogEntry; user = u, content_type = get_for_model(obj), object_id = pk_string(obj),
           object_repr = first(string(obj), 200), action_flag = flag,
           change_message = isempty(message) ? (flag == ADDITION ? "Added." : flag == DELETION ? "Deleted." : "No fields changed.") : message)
end

Base.show(io::IO, e::LogEntry) = print(io, e.action_flag == ADDITION ? "Added" : e.action_flag == DELETION ? "Deleted" : "Changed",
                                      " “", e.object_repr, "”")
tattr(e::LogEntry, ::Val{:is_addition}) = e.action_flag == ADDITION
tattr(e::LogEntry, ::Val{:is_change}) = e.action_flag == CHANGE
tattr(e::LogEntry, ::Val{:is_deletion}) = e.action_flag == DELETION
