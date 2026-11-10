@form CommentForm begin
    name = CharField(max_length = 80, label = "Your name")
    body = TextField(label = "Comment", validators = [s -> length(s) >= 3 || "Say a little more (3+ characters)."])
end
