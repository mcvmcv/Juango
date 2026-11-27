# Django's project_template tests, ported (#227): TestStartProjectSettings. The project `startproject` makes keeps
# Juango's default MIDDLEWARE (its settings.jl doesn't set it), so the headers checked are those of the defaults.
# julia --project=test test/django_project_template.jl   (see setup.jl)
#
# Not translated: test_mailers (Django 6's MAILERS setting; Juango's EMAIL_BACKEND is tested in django_mail).
@isdefined(TEST_SETUP_DONE) || include("setup.jl")

dpt_empty(req) = HttpResponse("")
const DPT_URLS = Any[path("empty/", dpt_empty)]

@testset "django project_template: TestStartProjectSettings" begin
    # the project's settings.jl leaves MIDDLEWARE to the default
    dir = mktempdir()
    redirect_stdout(devnull) do
        Juango.startproject("dptsite"; dir = dir, develop = false)
    end
    @test !occursin("MIDDLEWARE", read(joinpath(dir, "dptsite", "settings.jl"), String))
    # test_middleware_headers: the default MIDDLEWARE's headers on an empty response, and never "Vary: Cookie"
    # (which would keep caches from caching the response)
    override_settings(MIDDLEWARE = Juango.default_settings()[:MIDDLEWARE], ROOT_URLCONF = DPT_URLS) do
        r = get(Client(), "/empty/")
        headers = sort(["$k: $v" for (k, v) in r.headers])
        @test headers == ["Content-Length: 0",
                          "Content-Type: text/html; charset=utf-8",
                          "Cross-Origin-Opener-Policy: same-origin",
                          "Referrer-Policy: same-origin",
                          "X-Content-Type-Options: nosniff",
                          "X-Frame-Options: DENY"]
        @test !any(h -> startswith(lowercase(h), "vary:") && occursin("cookie", lowercase(h)), headers)
    end
end
