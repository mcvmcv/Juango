# Django's utils_tests test_os_utils.py, ported (#227): safe_join.
# julia --project=test test/django_utils_os.jl   (see setup.jl; no database needed)
#
# Not translated: safe_makedirs (Python's os.makedirs with modes; Julia's mkpath) and to_path (pathlib).
@isdefined(TEST_SETUP_DONE) || include("setup.jl")

@testset "django utils_tests test_os_utils: SafeJoinTests" begin
    @test Juango.safe_join("/abc/", "abc") == "/abc/abc"                 # test_base_path_ends_with_sep
    @test Juango.safe_join("/", "path") == "/path" && Juango.safe_join("/", "") == "/"     # test_root_path
    @test_throws Juango.BadRequest Juango.safe_join("/abc/", "../def")     # test_parent_path
end
