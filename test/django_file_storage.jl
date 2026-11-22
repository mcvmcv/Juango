# Django's file storage tests, ported (#227): tests/file_storage (FileStorageTests for FileSystemStorage,
# the InMemoryStorage tests, FileStoragePathParsing, get_available_name with max_length, FileField uploads).
# julia --project=test test/django_file_storage.jl   (see setup.jl)
#
# Differences kept: Juango drops leading dots from stored names (".htaccess" is stored as "htaccess"),
# refuses an empty location instead of using the working directory, raises ArgumentError where Django
# raises SuspiciousFileOperation, and has no get_accessed_time (Julia's stat has no atime). Each test keeps
# its Django name in a comment.
@isdefined(TEST_SETUP_DONE) || include("setup.jl")

@model struct DfsDocument
    myfile = FileField(upload_to = "docs/", max_length = 30)
    Meta(table = "dfs_document")
end
redirect_stdout(devnull) do
    Juango.sync_models!([DfsDocument]); push!(PORT_MODELS, DfsDocument)
end

function dfs_common(s, label)
    @testset "storage basics ($label)" begin
        @test !exists(s, "storage_test")                                                  # test_file_access_options
        name = save_file(s, "storage_test", Vector{UInt8}("storage contents"))
        @test name == "storage_test" && exists(s, name) && String(read(s, name)) == "storage contents"
        @test size(s, name) == length("storage contents")                                 # test_file_get_size
        delete_file(s, name)
        @test !exists(s, name)
        name = save_file(s, "path/to/test.file", Vector{UInt8}("file saved with path"))  # test_file_save_with_path
        @test exists(s, "path") && exists(s, "path/to") && String(read(s, "path/to/test.file")) == "file saved with path"
        delete_file(s, "path/to/test.file")
        @test_throws ArgumentError delete_file(s, "")                                     # test_delete_no_name
        n1 = save_file(s, "CaSe_SeNsItIvE", Vector{UInt8}("x"))                           # test_file_storage_preserves_filename_case
        @test n1 == "CaSe_SeNsItIvE"
        a = save_file(s, "dup.txt", Vector{UInt8}("1")); b = save_file(s, "dup.txt", Vector{UInt8}("2"))   # (an existing name: a new one)
        @test a == "dup.txt" && occursin(r"^dup_[A-Za-z0-9]{7}\.txt$", b) && String(read(s, a)) == "1"
        t = save_file(s, "archive.tar.gz", Vector{UInt8}("1")); t2 = save_file(s, "archive.tar.gz", Vector{UInt8}("2"))
        @test occursin(r"^archive_[A-Za-z0-9]{7}\.tar\.gz$", t2)                         # (all the extensions kept)
        d1 = save_file(s, "dotted.path/test", Vector{UInt8}("1")); d2 = save_file(s, "dotted.path/test", Vector{UInt8}("2"))   # FileStoragePathParsing: test_directory_with_dot
        @test d1 == "dotted.path/test" && occursin(r"^dotted\.path/test_[A-Za-z0-9]{7}$", d2)
        dirs, files = Juango.listdir(s, "")                                               # test_listdir
        @test "dotted.path" in dirs && "CaSe_SeNsItIvE" in files && "dup.txt" in files
        n = save_file(s, "timed.txt", Vector{UInt8}("x"))                                 # test_file_get_modified_time, test_file_get_created_time
        override_settings(USE_TZ = false) do
            m = get_modified_time(s, n)
            @test m isa DateTime && abs(m - DateTime(Juango.TimeZones.astimezone(Juango.TimeZones.now(Juango.UTC_TZ), Juango.default_timezone()))) < Minute(1)
            @test get_created_time(s, n) isa DateTime
        end
        override_settings(USE_TZ = true) do
            m = get_modified_time(s, n)
            @test m isa Juango.TimeZones.ZonedDateTime && abs(DateTime(Juango.TimeZones.astimezone(m, Juango.UTC_TZ)) - now(Dates.UTC)) < Minute(1)
        end
        @test Juango.get_available_name(s, "x" ^ 10 * ".txt"; max_length = 50) == "x" ^ 10 * ".txt"   # test_get_available_name (free: as it is)
        long = Juango.get_available_name(s, "dup.txt"; max_length = 13)                  # (taken, and room for the suffix only by cutting the stem)
        @test length(long) <= 13 && endswith(long, ".txt")
        e = try Juango.get_available_name(s, "dup.txt"; max_length = 5) catch e; e end   # (nothing fits)
        @test e isa ArgumentError && occursin("Storage can not find an available filename", e.msg)
        for p in ("/test_media_url/", "/test_media_url")                                 # test_file_url, test_base_url
            st = s isa InMemoryStorage ? InMemoryStorage(; base_url = p) : FileSystemStorage(s.location, p)
            @test Juango.url(st, "test.file") == "/test_media_url/test.file"
            @test Juango.url(st, "~!*()'@#\$%^&*abc`+ =.file") == "/test_media_url/~!*()'%40%23%24%25%5E%26*abc%60%2B%20%3D.file"
            @test Juango.url(st, "ab\0c") == "/test_media_url/ab%00c"
            @test Juango.url(st, "a/b\\c.file") == "/test_media_url/a/b/c.file"
            for evil in ("/evil.com", "\\evil.com", "///evil.com", "\\\\\\evil.com")       # (#25905: no leading slashes)
                @test Juango.url(st, evil) == "/test_media_url/evil.com"
            end
            @test Juango.url(st, nothing) == "/test_media_url/"
        end
    end
end

@testset "django file_storage" begin
    dir = mktempdir()
    fs = FileSystemStorage(dir, "/test_media_url/")
    dfs_common(fs, "FileSystemStorage")
    @test Juango.path(fs, "test.file") == joinpath(dir, "test.file")                      # test_file_path
    @test_throws ArgumentError exists(fs, "..")                                           # test_file_storage_prevents_directory_traversal
    @test_throws ArgumentError exists(fs, "/etc/passwd")
    mkpath(joinpath(dir, "emptydir"))                                                     # test_delete_deletes_directories
    delete_file(fs, "emptydir")
    @test !isdir(joinpath(dir, "emptydir"))
    old = settings.MEDIA_ROOT                                                             # test_setting_changed (no location: MEDIA_ROOT, read when used)
    d2 = mktempdir()
    override_settings(MEDIA_ROOT = d2) do
        n = save_file(FileSystemStorage(), "follows.txt", Vector{UInt8}("x"))
        @test isfile(joinpath(d2, n))
    end
    ms = InMemoryStorage(; base_url = "/test_media_url/")                                 # InMemoryStorageTests
    dfs_common(ms, "InMemoryStorage")
    @test_throws ArgumentError Juango.path(ms, "x")
    @test Juango.get_valid_name("john's portrait in 2004.jpg") == "johns_portrait_in_2004.jpg"   # test_get_valid_filename
    @test Juango.get_valid_name("a  b.txt") == "a__b.txt"                                 # (each space: an underscore)

    old_storage = settings.DEFAULT_FILE_STORAGE                                           # FileFieldStorageTests: a long upload name fits max_length
    mem = InMemoryStorage()
    configure!(DEFAULT_FILE_STORAGE = mem)
    try
        port_block() do
            up = UploadedFile("a"^40 * ".txt", "content")
            d = save!(DfsDocument(myfile = up))
            @test length(d.myfile.name) <= 30 && startswith(d.myfile.name, "docs/") && endswith(d.myfile.name, ".txt")
            @test String(read(d.myfile)) == "content"
            d2 = save!(DfsDocument(myfile = UploadedFile("a"^40 * ".txt", "other")))
            @test d2.myfile.name != d.myfile.name && length(d2.myfile.name) <= 30
            @test get(DfsDocument; id = d.id).myfile.name == d.myfile.name
        end
    finally
        configure!(DEFAULT_FILE_STORAGE = old_storage)
    end
    # not translated: custom storage classes' Python hooks (generate_filename, deconstruct), file locking,
    # makedirs/remove races, permissions modes as options (Juango reads FILE_UPLOAD_PERMISSIONS), pathlib names
end
