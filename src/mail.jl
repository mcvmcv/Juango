# Email ------------------------------------------------------------------------------------------------
#
#     send_mail("Welcome", "Hi Ann!", "site@example.com", ["ann@example.com"]; html_message = "<p>Hi Ann!</p>")
#     msg = EmailMessage("Report", "See attached."; to = ["boss@example.com"], cc = [...], reply_to = [...])
#     attach!(msg, "report.csv", csv_text, "text/csv")
#     send!(msg)
#
# EMAIL_BACKEND picks the backend: :smtp (default), :console, :file (EMAIL_FILE_PATH), :locmem
# (messages collect in `Juango.outbox`; the test Client switches to it) or :dummy.

"""
    EmailMessage(subject, body; from_email=settings.DEFAULT_FROM_EMAIL, to=[], cc=[], bcc=[],
                 reply_to=[], headers=Dict(), attachments=[], alternatives=[])

An email. `attachments` are `(filename, content, mimetype)` tuples and `alternatives`
`(content, mimetype)` pairs, e.g. an HTML version. BCC recipients get the message but
aren't listed in its headers.
"""
mutable struct EmailMessage
    subject::String
    body::String
    from_email::String
    to::Vector{String}
    cc::Vector{String}
    bcc::Vector{String}
    reply_to::Vector{String}
    headers::Dict{String,String}
    attachments::Vector{Tuple{String,Vector{UInt8},String}}
    alternatives::Vector{Tuple{String,String}}
end
EmailMessage(subject, body; from_email = nothing, to = String[], cc = String[], bcc = String[], reply_to = String[],
             headers = Dict{String,String}(), attachments = [], alternatives = []) =
    EmailMessage(string(subject), string(body), string(something(from_email, settings.DEFAULT_FROM_EMAIL)),
                 string.(collect(to)), string.(collect(cc)), string.(collect(bcc)), string.(collect(reply_to)),
                 Dict{String,String}(string(k) => string(v) for (k, v) in headers),
                 [(string(a[1]), bytesof(a[2]), string(a[3])) for a in attachments],
                 [(string(a[1]), string(a[2])) for a in alternatives])
"An `EmailMessage` meant to carry alternatives (`attach_alternative!(msg, html, \"text/html\")`)."
const EmailMultiAlternatives = EmailMessage
bytesof(x::AbstractString) = Vector{UInt8}(codeunits(x))
bytesof(x::AbstractVector{UInt8}) = Vector{UInt8}(x)
bytesof(x::UploadedFile) = copy(x.data)

"Attach a file: `attach!(msg, \"report.pdf\", bytes, \"application/pdf\")`."
attach!(m::EmailMessage, filename, content, mimetype = "application/octet-stream") =
    (push!(m.attachments, (string(filename), bytesof(content), string(mimetype))); m)
"Add an alternative rendering, usually HTML."
attach_alternative!(m::EmailMessage, content, mimetype = "text/html") = (push!(m.alternatives, (string(content), string(mimetype))); m)
"Everyone the message is delivered to (to, cc and bcc)."
recipients(m::EmailMessage) = unique(vcat(m.to, m.cc, m.bcc))

# --- MIME ----------------------------------------------------------------------------------------------

"RFC 2047 encoding for header text that isn't plain ASCII."
encode_header(s) = all(c -> isascii(c) && c != '\n' && c != '\r', s) ? s : "=?utf-8?b?" * base64encode(s) * "?="
nonl(s) = replace(s, r"[\r\n]+" => " ")     # no header injection
wrap76(s) = join([s[i:min(end, i + 75)] for i in 1:76:length(s)], "\r\n")
b64part(data) = wrap76(base64encode(data))

function text_part(io, content, mimetype)
    print(io, "Content-Type: $mimetype; charset=utf-8\r\nContent-Transfer-Encoding: base64\r\n\r\n", b64part(content), "\r\n")
end

"The message in RFC 5322 / MIME form, as sent."
function message_string(m::EmailMessage; message_id = nothing)
    io = IOBuffer()
    hdr(k, v) = print(io, k, ": ", nonl(v), "\r\n")
    hdr("From", encode_header(m.from_email))
    isempty(m.to) || hdr("To", join(m.to, ", "))
    isempty(m.cc) || hdr("Cc", join(m.cc, ", "))
    isempty(m.reply_to) || hdr("Reply-To", join(m.reply_to, ", "))
    hdr("Subject", encode_header(m.subject))
    hdr("Date", Dates.format(now(Dates.UTC), "e, dd u yyyy HH:MM:SS") * " +0000")
    domain = (i = findlast('@', m.from_email); i === nothing ? "localhost" : strip(m.from_email[i+1:end], '>'))
    hdr("Message-ID", something(message_id, "<" * random_string(24) * "@" * domain * ">"))
    hdr("MIME-Version", "1.0")
    for (k, v) in m.headers
        hdr(k, v)
    end
    body = IOBuffer()
    if isempty(m.alternatives)
        text_part(body, m.body, "text/plain")
    else
        b = "alt-" * random_string(20)
        print(body, "Content-Type: multipart/alternative; boundary=\"$b\"\r\n\r\n")
        print(body, "--$b\r\n"); text_part(body, m.body, "text/plain")
        for (c, t) in m.alternatives
            print(body, "--$b\r\n"); text_part(body, c, t)
        end
        print(body, "--$b--\r\n")
    end
    if isempty(m.attachments)
        write(io, take!(body))
    else
        b = "mixed-" * random_string(20)
        print(io, "Content-Type: multipart/mixed; boundary=\"$b\"\r\n\r\n--$b\r\n")
        write(io, take!(body))
        for (name, data, t) in m.attachments
            print(io, "--$b\r\nContent-Type: $t\r\nContent-Transfer-Encoding: base64\r\n",
                  "Content-Disposition: attachment; filename=\"", replace(nonl(encode_header(name)), "\"" => ""), "\"\r\n\r\n",
                  b64part(data), "\r\n")
        end
        print(io, "--$b--\r\n")
    end
    String(take!(io))
end

# --- backends --------------------------------------------------------------------------------------------

"Messages sent with the `:locmem` backend (the test Client's)."
const outbox = EmailMessage[]

function email_backend()
    b = settings.EMAIL_BACKEND
    b isa Function && return b
    b === :smtp && return smtp_send
    b === :console && return msgs -> (foreach(m -> (println(message_string(m)); println("-"^79)), msgs); length(msgs))
    b === :locmem && return msgs -> (append!(outbox, msgs); length(msgs))
    b === :dummy && return msgs -> length(msgs)
    if b === :file
        return function (msgs)
            dir = string(settings.EMAIL_FILE_PATH)
            isempty(dir) && throw(ImproperlyConfigured("EMAIL_BACKEND = :file needs EMAIL_FILE_PATH"))
            mkpath(dir)
            path = joinpath(dir, Dates.format(now(), "yyyymmdd-HHMMSS") * "-" * random_string(8) * ".log")
            open(path, "a") do io
                foreach(m -> (println(io, message_string(m)); println(io, "-"^79)), msgs)
            end
            length(msgs)
        end
    end
    throw(ImproperlyConfigured("unknown EMAIL_BACKEND $(repr(b))"))
end

"""
    send!(msg; fail_silently=false) -> number of messages sent (0 or 1)
"""
function send!(m::EmailMessage; fail_silently = false)
    isempty(recipients(m)) && return 0
    try
        return email_backend()([m])
    catch e
        fail_silently || rethrow()
        @warn "Sending email failed" exception = e
        return 0
    end
end

"""
    send_mail(subject, message, from_email, recipient_list; html_message=nothing, fail_silently=false) -> Int

Send one message to every address in `recipient_list` (they all see each other in To).
`from_email = nothing` uses `DEFAULT_FROM_EMAIL`.
"""
function send_mail(subject, message, from_email, recipient_list; html_message = nothing, fail_silently = false)
    m = EmailMessage(subject, message; from_email = from_email, to = recipient_list)
    html_message === nothing || attach_alternative!(m, html_message, "text/html")
    send!(m; fail_silently = fail_silently)
end

"Email the site administrators (`settings.ADMINS`, a list of `(name, email)`)."
function mail_admins(subject, message; html_message = nothing, fail_silently = false)
    isempty(settings.ADMINS) && return 0
    m = EmailMessage(settings.EMAIL_SUBJECT_PREFIX * subject, message; from_email = settings.SERVER_EMAIL,
                     to = [a isa Tuple || a isa Pair ? last(a) : a for a in settings.ADMINS])
    html_message === nothing || attach_alternative!(m, html_message, "text/html")
    send!(m; fail_silently = fail_silently)
end

# --- SMTP ---------------------------------------------------------------------------------------------------

addr_only(s) = (m = match(r"<([^>]+)>", s); m === nothing ? strip(s) : m[1])

function smtp_read(io)
    lines = String[]
    while true
        l = readline(io)
        isempty(l) && eof(io) && throw(ErrorException("SMTP connection closed"))
        push!(lines, l)
        (length(l) < 4 || l[4] != '-') && break
    end
    code = parse(Int, first(lines[end], 3))
    code, join(lines, "\n")
end
function smtp_cmd(io, cmd, expect)
    write(io, cmd * "\r\n")
    code, text = smtp_read(io)
    code in expect || throw(ErrorException("SMTP error after '$(first(split(cmd, ' ')))': $text"))
    code, text
end

"""
Send with SMTP (`EMAIL_HOST`, `EMAIL_PORT`, `EMAIL_HOST_USER`, `EMAIL_HOST_PASSWORD`,
`EMAIL_USE_TLS` for STARTTLS, `EMAIL_USE_SSL` for implicit TLS, `EMAIL_TIMEOUT` in seconds
for the whole conversation).
"""
function smtp_send(msgs)
    host, port = string(settings.EMAIL_HOST), Int(settings.EMAIL_PORT)
    tcp = TCP.connect((occursin(':', host) ? "[$host]" : host) * ":$port")
    timeout = settings.EMAIL_TIMEOUT
    timeout === nothing || TCP.set_deadline!(tcp, time_ns() + round(Int64, timeout * 1e9))
    io = settings.EMAIL_USE_SSL ? tls_wrap(tcp, host) : tcp
    sent = 0
    try
        smtp_read(io)[1] == 220 || throw(ErrorException("SMTP server didn't greet us"))
        me = gethostname()
        _, ehlo = smtp_cmd(io, "EHLO $me", (250,))
        if settings.EMAIL_USE_TLS && !settings.EMAIL_USE_SSL
            occursin(r"STARTTLS"i, ehlo) || throw(ErrorException("SMTP server doesn't offer STARTTLS"))
            smtp_cmd(io, "STARTTLS", (220,))
            io = tls_wrap(tcp, host)
            _, ehlo = smtp_cmd(io, "EHLO $me", (250,))
        end
        user = string(settings.EMAIL_HOST_USER)
        if !isempty(user)
            smtp_cmd(io, "AUTH PLAIN " * base64encode("\0" * user * "\0" * string(settings.EMAIL_HOST_PASSWORD)), (235,))
        end
        for m in msgs
            rcpts = recipients(m)
            isempty(rcpts) && continue
            smtp_cmd(io, "MAIL FROM:<$(addr_only(m.from_email))>", (250,))
            foreach(r -> smtp_cmd(io, "RCPT TO:<$(addr_only(r))>", (250, 251)), rcpts)
            smtp_cmd(io, "DATA", (354,))
            data = replace(message_string(m), r"(?m)^\." => "..")        # dot-stuffing
            write(io, data * (endswith(data, "\r\n") ? "" : "\r\n") * ".\r\n")
            code, text = smtp_read(io)
            code == 250 || throw(ErrorException("SMTP server refused the message: $text"))
            sent += 1
        end
        try smtp_cmd(io, "QUIT", (221,)) catch end
    finally
        close(io)
    end
    sent
end

"Start TLS on an open SMTP connection, verifying the server's certificate for `host`."
function tls_wrap(tcp, host)
    conn = TLS.client(tcp, TLS.Config(; server_name = host))
    TLS.handshake!(conn)
    conn
end
