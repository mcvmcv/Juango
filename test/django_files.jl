# Django's files tests, ported (#227): get_image_dimensions (GetImageDimensionsTests, InconsistentGetImageDimensionsBug).
# julia --project=test test/django_files.jl   (see setup.jl; no database needed)
#
# Not translated: File, ContentFile, the temporary and in-memory uploaded files, locks, file_move_safe and spooled
# temporary files (Python's file objects: Juango's uploads are UploadedFile values and its stored files FieldFile, tested
# in django_file_uploads.jl and django_file_storage.jl); Pillow's parser.
@isdefined(TEST_SETUP_DONE) || include("setup.jl")

@testset "django files: GetImageDimensionsTests" begin
    fx(name) = joinpath(@__DIR__, "files_fixtures", name)
    @test Juango.get_image_dimensions(fx("brokenimg.png")) == (nothing, nothing)          # test_invalid_image
    @test Juango.get_image_dimensions("missing.png") == (nothing, nothing)                # test_missing_file
    @test Juango.get_image_dimensions(fx("test.webp")) == (540, 405)                       # test_webp
    # test_multiple_calls: the same size each time, the file left where it was
    open(fx("test.png")) do io
        s1 = Juango.get_image_dimensions(io)
        s2 = Juango.get_image_dimensions(io)
        @test s1 == s2 == (16, 16) && position(io) == 0
    end
    @test Juango.get_image_dimensions(fx("magic.png")) == (666, 666)                       # test_bug_19457
    @test Juango.get_image_dimensions(read(fx("test1.png"))) == (16, 16)
end
