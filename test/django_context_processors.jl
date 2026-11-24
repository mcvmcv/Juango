# Django's context_processors tests, ported (#227).
# julia --project=test test/django_context_processors.jl   (see setup.jl)
#
# Not translated: test_sql_queries' "other" database (Juango's multi-database tests are in db.jl).
@isdefined(TEST_SETUP_DONE) || include("setup.jl")

@model struct DcpDebugObject
    Meta(table = "dcp_debugobject")
end
redirect_stdout(devnull) do
    Juango.sync_models!(Any[DcpDebugObject]); push!(PORT_MODELS, DcpDebugObject)
end

write(joinpath(TPL, "dcp_request_attrs.html"), """
{% if request %}Have request{% else %}No request{% endif %}
{% if request.is_secure %}Secure{% else %}Not secure{% endif %}
{{ request.path }}""")
write(joinpath(TPL, "dcp_debug.html"), """
{% if debug == True %}Have debug
First query list: {{ sql_queries|length }}
{% for obj in debug_objects.all %}{{ obj }}{% endfor %}
Second query list: {{ sql_queries|length }}
{% for obj in debug_objects.all %}{{ obj }}{% endfor %}
Third query list: {{ sql_queries|length }}
{% endif %}""")
write(joinpath(TPL, "dcp_csp_nonce.html"), """<p>CSP Nonce is present: {{ csp_nonce }}</p>
<script nonce="{{ csp_nonce }}">console.log("ok");</script>""")

const DCP_URLS = Any[path("request_attrs/", req -> render(req, "dcp_request_attrs.html")),
                     path("debug/", req -> render(req, "dcp_debug.html", Dict("debug_objects" => objects(DcpDebugObject)))),
                     path("csp_nonce/", req -> render(req, "dcp_csp_nonce.html"))]

@testset "django context_processors" begin
    @testset "RequestContextProcessorTests" begin
        override_settings(ROOT_URLCONF = DCP_URLS, CONTEXT_PROCESSORS = Any[Juango.cp_request]) do
            # test_request_attributes: request attributes can't be overridden by GET and POST (#3828)
            url = "/request_attrs/"
            c = Client()
            @test assert_contains(get(c, url), "Have request")
            @test assert_contains(get(c, url), "Not secure")
            @test assert_contains(get(c, url; data = Dict("is_secure" => "blah")), "Not secure")
            @test assert_contains(post(c, url; data = Dict("is_secure" => "blah")), "Not secure")
            @test assert_contains(get(c, url), url)
            @test assert_contains(get(c, url; data = Dict("path" => "/blah/")), url)
            @test assert_contains(post(c, url; data = Dict("path" => "/blah/")), url)
        end
    end

    @testset "DebugContextProcessorTests" begin
        override_settings(DEBUG = true, INTERNAL_IPS = ["127.0.0.1"], ROOT_URLCONF = DCP_URLS,
                          CONTEXT_PROCESSORS = Any[Juango.cp_debug]) do
            # test_debug
            @test assert_contains(get(Client(), "/debug/"), "Have debug")
            override_settings(DEBUG = false) do
                @test assert_not_contains(get(Client(), "/debug/"), "Have debug")
            end
            # test_sql_queries: sql_queries is the queries run so far, not a copy made once (#23364)
            r = get(Client(), "/debug/")
            @test assert_contains(r, "First query list: 0")
            @test assert_contains(r, "Second query list: 1")
            @test assert_contains(r, "Third query list: 2")
            # (and only for INTERNAL_IPS)
            override_settings(INTERNAL_IPS = String[]) do
                @test assert_not_contains(get(Client(), "/debug/"), "Have debug")
            end
        end
        @test isempty(connection_queries())          # (DEBUG off: nothing is kept)
    end

    @testset "CSPContextProcessorTests" begin
        override_settings(ROOT_URLCONF = DCP_URLS, CONTEXT_PROCESSORS = Any[Juango.cp_csp],
                          MIDDLEWARE = Any[ContentSecurityPolicyMiddleware],
                          SECURE_CSP = Dict("script-src" => [CSP.SELF, CSP.NONCE])) do
            r = get(Client(), "/csp_nonce/")
            @test haskey(r.context, "csp_nonce")                                     # test_csp_nonce_in_context
            nonce = string(r.context["csp_nonce"])
            @test occursin("'nonce-$nonce'", getheader(r, "Content-Security-Policy"))  # test_csp_nonce_in_header
            @test occursin("<script nonce=\"$nonce\">", text(r))                      # test_csp_nonce_in_template
            @test length(nonce) == 22                                                # test_csp_nonce_length
            @test string(get(Client(), "/csp_nonce/").context["csp_nonce"]) != nonce # test_different_nonce_per_request
            override_settings(MIDDLEWARE = Any[]) do                                 # test_csp_nonce_in_context_no_middleware
                @test haskey(get(Client(), "/csp_nonce/").context, "csp_nonce")
            end
        end
    end
end
