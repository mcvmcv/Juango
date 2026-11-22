# Django's mail tests, ported (#227): tests/mail (MailTests, the backend tests for locmem, console,
# file and dummy).
# julia --project=test test/django_mail.jl   (see setup.jl)
#
# Juango's message is rendered by message_string (Django's message() returns an email.message
# object): the tests read its headers back. Juango encodes header text as base64 (Django: quoted-
# printable or base64), and its body parts are always base64. Each test keeps its Django name in a comment.
@isdefined(TEST_SETUP_DONE) || include("setup.jl")

"The headers of a rendered message, in order, as name => value pairs."
function dml_headers(m::EmailMessage)
    s = Juango.message_string(m)
    head = s[1:first(findfirst("\r\n\r\n", s)) - 1]
    [String(strip(k)) => String(strip(v)) for (k, v) in (split(l, ':'; limit = 2) for l in split(head, "\r\n") if occursin(':', l))]
end
dml_get(hs, name) = (i = findfirst(p -> lowercase(p.first) == lowercase(name), hs); i === nothing ? nothing : hs[i].second)
dml_count(hs, name) = count(p -> lowercase(p.first) == lowercase(name), hs)
dml_b64(s) = "=?utf-8?b?" * Juango.base64encode(s) * "?="

@testset "django mail: MailTests" begin
    m = EmailMessage("Subject", "Content"; from_email = "from@example.com", to = ["to@example.com"])   # test_ascii
    hs = dml_headers(m)
    @test dml_get(hs, "Subject") == "Subject" && dml_get(hs, "From") == "from@example.com" && dml_get(hs, "To") == "to@example.com"
    @test m.body == "Content"
    m = EmailMessage("Subject", "Content"; from_email = "from@example.com", to = ["to@example.com", "other@example.com"])   # test_multiple_recipients
    @test dml_get(dml_headers(m), "To") == "to@example.com, other@example.com"
    m = EmailMessage("Subject", "Content"; from_email = "from@example.com", cc = ["cc@example.com"])   # test_header_omitted_for_no_to_recipients
    @test dml_get(dml_headers(m), "To") === nothing && Juango.recipients(m) == ["cc@example.com"]
    m = EmailMessage("Subject", "Content"; to = ["to@example.com", ""], cc = ["cc@example.com", ""], bcc = ["", "bcc@example.com"])   # test_recipients_with_empty_strings
    @test Juango.recipients(m) == ["to@example.com", "cc@example.com", "bcc@example.com"]
    m = EmailMessage("Subject", "Content"; from_email = "from@example.com", to = ["to@example.com"], cc = ["cc@example.com"])   # test_cc
    @test dml_get(dml_headers(m), "Cc") == "cc@example.com" && Juango.recipients(m) == ["to@example.com", "cc@example.com"]
    m = EmailMessage("Subject", "Content"; to = ["to@example.com", "other@example.com"], cc = ["cc@example.com", "cc.other@example.com"])
    @test dml_get(dml_headers(m), "Cc") == "cc@example.com, cc.other@example.com" && length(Juango.recipients(m)) == 4
    m = EmailMessage("Subject", "Content"; to = ["to@example.com"], cc = ["foo@example.com"], headers = Dict("Cc" => "override@example.com"))   # test_cc_headers
    hs = dml_headers(m)
    @test dml_get(hs, "Cc") == "override@example.com" && dml_count(hs, "Cc") == 1 && Juango.recipients(m) == ["to@example.com", "foo@example.com"]
    m = EmailMessage("Subject", "Content"; to = ["to@example.com"], headers = Dict("Cc" => "foo@example.com"))   # test_cc_in_headers_only
    @test dml_get(dml_headers(m), "Cc") == "foo@example.com" && Juango.recipients(m) == ["to@example.com"]
    m = EmailMessage("Subject", "Content"; to = ["to@example.com"], bcc = ["bcc@example.com"])   # test_bcc_not_in_headers
    hs = dml_headers(m)
    @test dml_get(hs, "Bcc") === nothing && !occursin("bcc@example.com", Juango.message_string(m)) && Juango.recipients(m) == ["to@example.com", "bcc@example.com"]
    m = EmailMessage("Subject", "Content"; to = ["to@example.com"], reply_to = ["reply_to@example.com"])   # test_reply_to
    @test dml_get(dml_headers(m), "Reply-To") == "reply_to@example.com"
    m = EmailMessage("Subject", "Content"; to = ["to@example.com"], reply_to = ["reply_to1@example.com", "reply_to2@example.com"])
    @test dml_get(dml_headers(m), "Reply-To") == "reply_to1@example.com, reply_to2@example.com"
    m = EmailMessage("Subject", "Content"; to = ["to@example.com"], reply_to = ["foo@example.com"],   # test_reply_to_header
                     headers = Dict("Reply-To" => "override@example.com"))
    @test dml_get(dml_headers(m), "Reply-To") == "override@example.com" && dml_count(dml_headers(m), "Reply-To") == 1
    m = EmailMessage("Subject", "Content"; to = ["to@example.com"], headers = Dict("Reply-To" => "reply_to@example.com"))   # test_reply_to_in_headers_only
    @test dml_get(dml_headers(m), "Reply-To") == "reply_to@example.com"
    m = EmailMessage("Subject", "Content"; from_email = "bounce@example.com", to = ["to@example.com"],   # test_multiple_message_call
                     headers = Dict("From" => "from@example.com"))
    @test dml_get(dml_headers(m), "From") == "from@example.com" && dml_get(dml_headers(m), "From") == "from@example.com"
    @test dml_count(dml_headers(m), "From") == 1                                          # test_from_header
    m = EmailMessage("Subject", "Content"; to = ["to@example.com"], headers = Dict("From" => "from@example.com"))   # test_from_in_headers_only
    @test dml_get(dml_headers(m), "From") == "from@example.com"
    m = EmailMessage("Subject", "Content"; from_email = "bounce@example.com", to = ["list-subscriber@example.com", "list-subscriber2@example.com"],
                     headers = Dict("To" => "mailing-list@example.com"))                  # test_to_header
    @test dml_get(dml_headers(m), "To") == "mailing-list@example.com" && dml_count(dml_headers(m), "To") == 1
    @test Juango.recipients(m) == ["list-subscriber@example.com", "list-subscriber2@example.com"]
    m = EmailMessage("Subject", "Content"; to = ["list-subscriber@example.com"], headers = Dict("To" => "to@example.com"))
    @test dml_get(dml_headers(m), "To") == "to@example.com"
    m = EmailMessage("Subject", "Content"; headers = Dict("To" => "to@example.com"))       # test_to_in_headers_only
    @test dml_get(dml_headers(m), "To") == "to@example.com"
    for bad in ("Subject\nInjection Test", "Subject\rInjection Test", "Subject\r\nInjection Test")   # test_header_injection
        @test_throws BadHeaderError Juango.message_string(EmailMessage(bad, "Content"; to = ["to@example.com"]))
    end
    @test_throws BadHeaderError Juango.message_string(EmailMessage("Subject", "Content"; to = ["to@example.com"], headers = Dict("X-Custom" => "a\nb")))
    @test_throws BadHeaderError Juango.message_string(EmailMessage("Subject", "Content"; to = ["to@example.com\nBcc: evil@example.com"]))
    m = EmailMessage("Subject", "Content"; to = ["to@example.com"],                       # test_message_header_overrides
                     headers = Dict("date" => "Fri, 09 Nov 2001 01:08:47 -0000", "Message-ID" => "foo"))
    hs = dml_headers(m)
    @test dml_get(hs, "Date") == "Fri, 09 Nov 2001 01:08:47 -0000" && dml_count(hs, "Date") == 1
    @test dml_get(hs, "Message-ID") == "foo" && dml_count(hs, "Message-ID") == 1
    m = EmailMessage("Subject", "Content"; to = ["to@example.com"], headers = Dict("X-Custom" => "yes"))   # (other headers are added)
    @test dml_get(dml_headers(m), "X-Custom") == "yes"
    m = EmailMessage("Gżegżółka", "Content"; to = ["to@example.com"])                     # test_unicode_headers
    @test dml_get(dml_headers(m), "Subject") == dml_b64("Gżegżółka")
    m = EmailMessage("Subject", "Content"; from_email = "from@example.com",               # test_unicode_address_header
                     to = ["\"Firstname Sürname\" <to@example.com>", "other@example.com"])
    @test dml_get(dml_headers(m), "To") == dml_b64("Firstname Sürname") * " <to@example.com>, other@example.com"
    m = EmailMessage("Subject", "Content"; to = ["\"Sürname, Firstname\" <to@example.com>", "Firstname Sürname <other@example.com>"])
    @test dml_get(dml_headers(m), "To") == dml_b64("Sürname, Firstname") * " <to@example.com>, " * dml_b64("Firstname Sürname") * " <other@example.com>"
    m = EmailMessage("Subject", "Content"; from_email = "Fírstname Lástname <from@example.com>", to = ["Lastname, Firstname <to@example.com>"])
    hs = dml_headers(m)                                                                   # test_sanitize_address (specials quoted)
    @test dml_get(hs, "From") == dml_b64("Fírstname Lástname") * " <from@example.com>"
    @test dml_get(hs, "To") == "\"Lastname, Firstname\" <to@example.com>"
    @test Juango.format_address("A. Name <a@example.com>") == "\"A. Name\" <a@example.com>"
    @test Juango.format_address("\"Plain Name\" <a@example.com>") == "Plain Name <a@example.com>"
    @test Juango.format_address("<a@example.com>") == "a@example.com"
    m = EmailMessage(nothing, nothing; to = ["to@example.com"])                           # test_none_body
    @test m.subject == "" && m.body == ""
    for kw in (:to, :cc, :bcc, :reply_to)                                                 # test_to_argument_type (and cc, bcc, reply_to)
        e2 = try EmailMessage("Subject", "Content"; (kw => "foo@example.com",)...) catch e; e end
        @test e2 isa ArgumentError && e2.msg == "\"$kw\" argument must be a list or tuple"
    end
    @test EmailMessage("Subject", "Content"; to = ("to@example.com",)).to == ["to@example.com"]   # (a tuple is fine)

    m = EmailMessage("Subject", "Content"; to = ["to@example.com"])                       # test_attachments
    attach!(m, "an attachment.pdf", UInt8[0x25, 0x50, 0x44, 0x46], "application/pdf")
    attach!(m, "file.txt", "file content")                                                # test_attach_text_as_bytes (type guessed)
    attach!(m, "data.unknownext", "x")
    @test [a[3] for a in m.attachments] == ["application/pdf", "text/plain", "application/octet-stream"]
    s = Juango.message_string(m)
    @test occursin("Content-Type: multipart/mixed", s) && occursin("filename=\"an attachment.pdf\"", s) && occursin("Content-Type: text/plain\r\n", s)
    m = EmailMessage("Subject", "Content"; to = ["to@example.com"], attachments = [("a.html", "<p>x</p>"), ("b.bin", UInt8[1], "application/x-custom")])
    @test [a[3] for a in m.attachments] == ["text/html", "application/x-custom"]          # test_attachments_two_tuple
    dir = mktempdir(); p = joinpath(dir, "sample.csv"); write(p, "a,b")                   # test_attach_file
    m = EmailMessage("Subject", "Content"; to = ["to@example.com"])
    attach_file(m, p)
    @test m.attachments == [("sample.csv", Vector{UInt8}("a,b"), "text/csv")]
    m = EmailMultiAlternatives("Subject", "text content"; to = ["to@example.com"])        # test_alternatives
    attach_alternative!(m, "<p>html content</p>", "text/html")
    s = Juango.message_string(m)
    @test occursin("multipart/alternative", s) && occursin(Juango.base64encode("<p>html content</p>"), s) && !occursin("multipart/mixed", s)
end

@testset "django mail: sending" begin
    old = (settings.EMAIL_BACKEND, settings.ADMINS, settings.MANAGERS, settings.SERVER_EMAIL, settings.EMAIL_SUBJECT_PREFIX)
    configure!(EMAIL_BACKEND = :locmem)
    try
        empty!(outbox)                                                                    # test_send_mail (html_message)
        @test send_mail("Subject", "Content", "from@example.com", ["to@example.com"]; html_message = "<p>HTML</p>") == 1
        m = only(outbox)
        @test m.alternatives == [("<p>HTML</p>", "text/html")] && m.to == ["to@example.com"]
        empty!(outbox)                                                                    # test_send_messages_zero_sent
        @test send!(EmailMessage("Subject", "Content"; to = String[])) == 0 && isempty(outbox)
        @test send_messages(get_connection(), EmailMessage[]) == 0
        configure!(ADMINS = [("nobody", "nobody@example.com")], MANAGERS = [("nobody", "nobody@example.com")],   # test_mail_admins_and_managers
                   SERVER_EMAIL = "send_mail@example.com", EMAIL_SUBJECT_PREFIX = "[Django] ")
        empty!(outbox)
        mail_admins("Subject", "Content"); mail_managers("Subject", "Content")
        @test length(outbox) == 2 && all(m -> m.subject == "[Django] Subject" && m.to == ["nobody@example.com"] && m.from_email == "send_mail@example.com", outbox)
        empty!(outbox)                                                                    # test_html_mail_admins, test_html_mail_managers
        mail_admins("Subject", "Content"; html_message = "<p>HTML</p>"); mail_managers("Subject", "Content"; html_message = "<p>HTML</p>")
        @test all(m -> m.body == "Content" && m.alternatives == [("<p>HTML</p>", "text/html")], outbox)
        configure!(EMAIL_SUBJECT_PREFIX = "")                                             # test_manager_and_admin_mail_prefix
        empty!(outbox)
        mail_admins("Subject", "Content")
        @test only(outbox).subject == "Subject"
        configure!(ADMINS = [], MANAGERS = [])                                            # test_empty_admins
        empty!(outbox)
        @test mail_admins("hi", "there") == 0 && mail_managers("hi", "there") == 0 && isempty(outbox)
        configure!(ADMINS = ["admin@example.com"])                                        # (ADMINS as plain addresses, Django 6's form)
        mail_admins("Subject", "Content")
        @test only(outbox).to == ["admin@example.com"]

        sent = EmailMessage[]                                                             # test_connection_arg (send_mail, mail_admins, mail_managers, send_mass_mail)
        conn = get_connection(msgs -> (append!(sent, msgs); length(msgs)))
        empty!(outbox)
        configure!(ADMINS = [("a", "admin@example.com")], MANAGERS = [("m", "manager@example.com")])
        send_mail("Subject", "Content", "from@example.com", ["to@example.com"]; connection = conn)
        mail_admins("Admin message", "Content"; connection = conn)
        mail_managers("Manager message", "Content"; connection = conn)
        @test send_mass_mail([("Subject1", "Content1", "from1@example.com", ["to1@example.com"]),
                              ("Subject2", "Content2", "from2@example.com", ["to2@example.com"])]; connection = conn) == 2
        @test [m.subject for m in sent] == ["Subject", "Admin message", "Manager message", "Subject1", "Subject2"] && isempty(outbox)
    finally
        configure!(EMAIL_BACKEND = old[1], ADMINS = old[2], MANAGERS = old[3], SERVER_EMAIL = old[4], EMAIL_SUBJECT_PREFIX = old[5])
    end
end

@testset "django mail: backends" begin
    old = (settings.EMAIL_BACKEND, settings.EMAIL_FILE_PATH)
    try
        configure!(EMAIL_BACKEND = :locmem)                                               # LocmemBackendTests
        empty!(outbox)
        c1, c2 = get_connection(), get_connection()                                       # test_locmem_shared_messages
        m = EmailMessage("Subject", "Content"; from_email = "bounce@example.com", to = ["to@example.com"], headers = Dict("From" => "from@example.com"))
        send_messages(c1, [m]); send_messages(c2, [m])
        @test length(outbox) == 2
        empty!(outbox)                                                                    # test_validate_multiline_headers
        @test_throws BadHeaderError send_mail("Subject\nMultiline", "Content", "from@example.com", ["to@example.com"])
        @test isempty(outbox)

        c = get_connection(:console)                                                      # ConsoleBackendTests: test_console_stream_kwarg
        path_, io = mktemp()
        n = redirect_stdout(io) do
            send_messages(c, [EmailMessage("Subject", "Content"; from_email = "from@example.com", to = ["to@example.com"]),
                              EmailMessage("Subject2", "Content"; from_email = "from@example.com", to = ["to@example.com"])])
        end
        close(io)
        out = read(path_, String)
        @test n == 2 && occursin("Subject: Subject\r\n", out) && occursin("Subject: Subject2\r\n", out) && count("-"^79, out) == 2
        path_, io = mktemp()                                                              # test_empty_admins (nothing printed)
        override_settings(EMAIL_BACKEND = :console, ADMINS = []) do
            redirect_stdout(() -> mail_admins("hi", "there"), io)
        end
        close(io)
        @test read(path_, String) == ""

        dir = mktempdir()                                                                 # FileBackendTests: test_file_sessions
        c = get_connection(:file)
        configure!(EMAIL_FILE_PATH = dir)
        @test send_messages(c, [EmailMessage("Subject", "Content"; to = ["to@example.com"]),
                                EmailMessage("Subject 2", "Content"; to = ["to@example.com"])]) == 2
        @test length(readdir(dir)) == 1                                                   # (one file per sending)
        txt = read(joinpath(dir, only(readdir(dir))), String)
        @test occursin("Subject: Subject\r\n", txt) && occursin("Subject: Subject 2\r\n", txt)
        send_messages(c, [EmailMessage("Subject 3", "Content"; to = ["to@example.com"])])
        @test length(readdir(dir)) == 2
        notdir = joinpath(dir, "afile"); write(notdir, "x")                               # test_file_path_not_a_directory
        configure!(EMAIL_FILE_PATH = notdir)
        e = try send_messages(c, [EmailMessage("S", "C"; to = ["to@example.com"])]) catch e; e end
        @test e isa Juango.ImproperlyConfigured && occursin("exists, but is not a directory", e.msg)

        c = get_connection(:dummy)                                                        # DummyBackendTests: test_dummy_backend
        m = EmailMessage("Subject", "Content"; to = ["to@example.com"])
        @test send_messages(c, [m, m, m]) == 3
    finally
        configure!(EMAIL_BACKEND = old[1], EMAIL_FILE_PATH = old[2])
    end
    # not translated: SMTP (Django's tests run an aiosmtpd server; Juango's SMTP backend has its own
    # tests in services.jl), the email.message API (message() objects, policy, MIME parts as objects),
    # quoted-printable and 7bit/8bit body encodings (Juango sends base64), RFC 2231 attachment file names,
    # punycode for non-ASCII domains, lazy strings, EMAIL_USE_LOCALTIME and DNS_NAME
end
