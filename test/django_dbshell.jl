# Django's dbshell tests, ported (#227): tests/dbshell (test_postgresql, test_mysql, test_sqlite, tests). Django's
# DatabaseClient.settings_to_cmd_args_env(settings, parameters) is Juango's `dbshell_args(backend, parameters)`; the
# settings are a database URL (options in its query string).
# julia --project=test test/django_dbshell.jl   (see setup.jl)
#
# Not translated: test_sigint_handler (Juango runs the client with disable_sigint; Julia's handler can't be inspected),
# MySQL's deprecated option names ("db", "passwd") and a settings dict without NAME (a URL always has its parts).
@isdefined(TEST_SETUP_DONE) || include("setup.jl")

dds_pg(url, params = String[]) = Juango.dbshell_args(Juango.PostgresBackend(url), params)
dds_my(url, params = String[]) = Juango.dbshell_args(Juango.MySQLBackend(url), params)

@testset "django dbshell: PostgreSqlDbshellCommandTestCase" begin
    @test dds_pg("postgresql://someuser:somepassword@somehost:444/dbname") ==                              # test_basic
          (["psql", "-U", "someuser", "-h", "somehost", "-p", "444", "dbname"], Dict("PGPASSWORD" => "somepassword"))
    @test dds_pg("postgresql://someuser@somehost:444/dbname") ==                                           # test_nopass
          (["psql", "-U", "someuser", "-h", "somehost", "-p", "444", "dbname"], nothing)
    @test dds_pg("postgresql://someuser@somehost:444/dbname?sslmode=verify-ca&sslrootcert=root.crt&sslcert=client.crt&sslkey=client.key") ==  # test_ssl_certificate
          (["psql", "-U", "someuser", "-h", "somehost", "-p", "444", "dbname"],
           Dict("PGSSLCERT" => "client.crt", "PGSSLKEY" => "client.key", "PGSSLMODE" => "verify-ca", "PGSSLROOTCERT" => "root.crt"))
    @test dds_pg("postgresql://?service=django_test") == (["psql"], Dict("PGSERVICE" => "django_test"))    # test_service
    @test dds_pg("postgresql://someuser@somehost:444/dbname?passfile=~/.custompgpass") ==                  # test_passfile
          (["psql", "-U", "someuser", "-h", "somehost", "-p", "444", "dbname"], Dict("PGPASSFILE" => "~/.custompgpass"))
    @test dds_pg("postgresql://?service=django_test&passfile=~/.custompgpass") ==
          (["psql"], Dict("PGSERVICE" => "django_test", "PGPASSFILE" => "~/.custompgpass"))
    @test dds_pg("postgresql://some%3Auser:some%3Apassword@[::1]:444/dbname") ==                           # test_column
          (["psql", "-U", "some:user", "-h", "::1", "-p", "444", "dbname"], Dict("PGPASSWORD" => "some:password"))
    @test dds_pg("postgresql://r%C3%B4le:s%C3%A9same@somehost:444/dbname") ==                              # test_accent
          (["psql", "-U", "rôle", "-h", "somehost", "-p", "444", "dbname"], Dict("PGPASSWORD" => "sésame"))
    @test dds_pg("postgresql:///dbname", ["--help"]) == (["psql", "--help", "dbname"], nothing)           # test_parameters
    # test_crash_password_does_not_leak: the password is only in the environment, so neither the command line
    # (visible to other users with ps) nor dbshell's error for a failed client (made from the arguments: Julia's own
    # ProcessFailedException shows the command's environment, so dbshell never lets one out) shows it
    args, env = dds_pg("postgresql://u:somepassword@h/db")
    @test !any(a -> occursin("somepassword", a), args) && env == Dict("PGPASSWORD" => "somepassword")
    c = addenv(Cmd(["sh", "-c", "exit 1"]), env)
    p = run(ignorestatus(c))
    @test p.exitcode == 1 && !occursin("somepassword", Juango.dbshell_failure(c, p))
end

@testset "django dbshell: MySqlDbshellCommandTestCase" begin
    @test dds_my("mysql://someuser:somepassword@somehost:444/somedbname") ==                             # test_basic_params_specified_in_settings
          (["mysql", "--user=someuser", "--host=somehost", "--port=444", "somedbname"], Dict("MYSQL_PWD" => "somepassword"))
    @test dds_my("mysql://someuser:somepassword@somehost:444/somedbname?charset=utf8mb4") ==             # test_options_charset
          (["mysql", "--user=someuser", "--host=somehost", "--port=444", "--default-character-set=utf8mb4", "somedbname"],
           Dict("MYSQL_PWD" => "somepassword"))
    @test dds_my("mysql://someuser:somepassword@localhost/somedbname?unix_socket=/path/to/mysql.socket.file") ==  # test_can_connect_using_sockets
          (["mysql", "--user=someuser", "--socket=/path/to/mysql.socket.file", "somedbname"], Dict("MYSQL_PWD" => "somepassword"))
    @test dds_my("mysql://someuser:somepassword@somehost:444/somedbname?ssl_ca=sslca&ssl_cert=sslcert&ssl_key=sslkey") ==  # test_ssl_certificate_is_added
          (["mysql", "--user=someuser", "--host=somehost", "--port=444", "--ssl-ca=sslca", "--ssl-cert=sslcert", "--ssl-key=sslkey", "somedbname"],
           Dict("MYSQL_PWD" => "somepassword"))
    args, env = dds_my("mysql://someuser@somehost:444/somedbname", ["--help"])                            # test_parameters
    @test args[end-1:end] == ["somedbname", "--help"] && env === nothing
    args, env = dds_my("mysql://someuser:somepassword@somehost:444/somedbname")                           # test_crash_password_does_not_leak
    @test !any(a -> occursin("somepassword", a), args) && env == Dict("MYSQL_PWD" => "somepassword")
end

@testset "django dbshell: SqliteDbshellCommandTestCase, DbshellCommandTestCase" begin
    @test Juango.dbshell_args(Juango.SQLiteBackend("test.db.sqlite3")) == (["sqlite3", "test.db.sqlite3"], nothing)        # test_path_name
    @test Juango.dbshell_args(Juango.SQLiteBackend("test.db.sqlite3"), ["-help"]) == (["sqlite3", "test.db.sqlite3", "-help"], nothing)  # test_parameters
    @test first(Juango.dbshell_cmd().exec) == (IS_POSTGRES ? "psql" : IS_MYSQL ? "mysql" : "sqlite3")
    # test_command_missing, test_non_zero_exit_status_when_path_to_db_is_path (with a stand-in client on PATH)
    dir = mktempdir()
    withenv("PATH" => dir) do
        exe = first(Juango.dbshell_cmd().exec)
        e = try Juango.dbshell(); nothing catch err; err end
        @test e isa CommandError && occursin("You appear not to have the '$exe' program installed or on your path.", e.msg)
        write(joinpath(dir, exe), "#!/bin/sh\nexit 1\n"); chmod(joinpath(dir, exe), 0o755)
        e = try Juango.dbshell(); nothing catch err; err end
        @test e isa CommandError && occursin("returned non-zero exit status 1.", e.msg) && startswith(e.msg, "\"$exe")
        @test !occursin("://", e.msg)                                                  # (no URL, so no password, in it)
    end
end
