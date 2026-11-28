# Django's utils_tests test_csp.py, ported (#227): the CSP source constants and build_policy (Juango's csp_header), the
# nonce in a policy, a nonce-only directive failing closed; the lazy nonce (Juango's {{ csp_nonce }}).
# julia --project=test test/django_utils_csp.jl   (see setup.jl; no database needed)
#
# Juango writes the directives in name order (Django's test compares them sorted). Not translated: LazyNonce's repr and
# Python's token_urlsafe patching.
@isdefined(TEST_SETUP_DONE) || include("setup.jl")

@testset "django utils_tests test_csp: CSPConstantsTests, CSPBuildPolicyTest, LazyNonceTests" begin
    CSP = Juango.CSP
    @test CSP.NONE == "'none'" && CSP.REPORT_SAMPLE == "'report-sample'" && CSP.SELF == "'self'" && CSP.STRICT_DYNAMIC == "'strict-dynamic'"
    @test CSP.UNSAFE_EVAL == "'unsafe-eval'" && CSP.UNSAFE_HASHES == "'unsafe-hashes'" && CSP.UNSAFE_INLINE == "'unsafe-inline'"
    @test CSP.WASM_UNSAFE_EVAL == "'wasm-unsafe-eval'" && CSP.NONCE == "<CSP_NONCE_SENTINEL>"
    bp(p; kw...) = sort(split(Juango.build_policy(p; kw...), "; "; keepempty = false))
    pol(s) = sort(split(s, "; "; keepempty = false))
    basic = Dict("default-src" => [CSP.SELF])
    @test bp(Dict()) == pol("")
    @test bp(basic) == pol("default-src 'self'")
    @test bp(Dict("default-src" => [CSP.SELF], "script-src" => [CSP.NONE])) == pol("default-src 'self'; script-src 'none'")
    @test bp(Dict("default-src" => CSP.SELF)) == pol("default-src 'self'")
    @test bp(Dict("default-src" => (CSP.SELF, "foo.com"))) == pol("default-src 'self' foo.com")
    @test bp(Dict("default-src" => Set([CSP.SELF, "foo.com", "bar.com"]))) == pol("default-src 'self' bar.com foo.com")
    @test bp(Dict("default-src" => [CSP.SELF], "script-src" => nothing)) == pol("default-src 'self'")
    @test bp(Dict("default-src" => [CSP.SELF], "block-all-mixed-content" => true)) == pol("default-src 'self'; block-all-mixed-content")
    @test bp(Dict("default-src" => [CSP.SELF], "block-all-mixed-content" => false)) == pol("default-src 'self'")
    @test bp(Dict("default-src" => [CSP.SELF], "block-all-mixed-content" => true, "upgrade-insecure-requests" => true)) ==
          pol("default-src 'self'; block-all-mixed-content; upgrade-insecure-requests")
    @test bp(basic; nonce = "abc123") == pol("default-src 'self'")
    @test bp(Dict("default-src" => [CSP.SELF, CSP.NONCE]); nonce = "abc123") == pol("default-src 'self' 'nonce-abc123'")
    @test bp(Dict("default-src" => [CSP.SELF, CSP.NONCE], "script-src" => [CSP.SELF, CSP.NONCE]); nonce = "abc123") ==
          pol("default-src 'self' 'nonce-abc123'; script-src 'self' 'nonce-abc123'")
    @test bp(Dict("default-src" => String[])) == pol("")
    @test bp(Dict("default-src" => [CSP.SELF], "script-src" => [CSP.NONCE])) == pol("default-src 'self'; script-src 'none'")
    @test bp(Dict("script-src" => CSP.NONCE)) == pol("script-src 'none'")
    @test bp(Dict("script-src" => [CSP.NONCE]); nonce = "abc123") == pol("script-src 'nonce-abc123'")
    @test bp(Dict("default-src" => [CSP.SELF, CSP.NONCE])) == pol("default-src 'self'")
    # LazyNonceTests: made on first use (22 characters, 16 random bytes), the same after
    req = Juango.Request("GET", "/")
    @test !haskey(req.meta, :csp_nonce)
    n1 = string(Juango.CspNonce(req))
    @test haskey(req.meta, :csp_nonce) && length(n1) == 22 && string(Juango.CspNonce(req)) == n1
end
