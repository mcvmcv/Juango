# Django's handler tests, ported (#227): tests/handlers (HandlerTests, TransactionsPerRequestTests,
# SignalsTests, HandlerRequestTests, the middleware factory checks).
# julia --project=test test/django_handlers.jl   (see setup.jl)
#
# WSGI/ASGI environ details (PATH_INFO types, SCRIPT_NAME) are Python's and aren't translated. Differences
# kept: request_finished is sent when the response is made, also for a streaming one (Django: when it's
# closed), and Juango has no SuspiciousOperation class (BadRequest is its 400). Each test keeps its Django
# name in a comment.
@isdefined(TEST_SETUP_DONE) || include("setup.jl")

dhn_regular(req) = HttpResponse("regular content")
dhn_none(req) = nothing
dhn_bad(req) = throw(BadRequest("Bad request in view"))
dhn_in_txn(req) = HttpResponse(get_autocommit() ? "autocommit" : "in a transaction")
dhn_get(req) = HttpResponse(get(req.GET, "want", "-"))

@testset "django handlers" begin
    old = (settings.ROOT_URLCONF, settings.MIDDLEWARE)
    configure!(ROOT_URLCONF = vcat(old[1], [path("dhn/regular/", dhn_regular), path("dhn/none/", dhn_none), path("dhn/bad/", dhn_bad),
                                            path("dhn/txn/", dhn_in_txn), path("dhn/notxn/", non_atomic_requests(req -> dhn_in_txn(req))),
                                            path("dhn/get/", dhn_get)]))
    try
        @testset "HandlerTests" begin
            r = get(Client(), "/dhn/get/?want=caf%C3%A9")                                 # test_non_ascii_query_string
            @test r.status == 200 && text(r) == "café"
            r = get(Client(), "/dhn/get/?want=caf%E9")                                    # (invalid UTF-8: replaced, not a 500)
            @test r.status == 200
            r = get(Client(; headers = Dict("cookie" => "want=\"caf\xe9\"")), "/dhn/regular/")   # test_invalid_unicode_cookie
            @test r.status == 200 && text(r) == "regular content"
            r = get(Client(; headers = Dict("cookie" => "want=caf%C3%A9")), "/dhn/regular/")    # test_non_ascii_cookie
            @test r.status == 200
            for bad in ("/~%A9helloworld", "/d%aao%aaw%aan%aal%aao%aaa%aad%aa/", "/%E2%99%E2%99%A5/", "/%E2%98%8E%E2%A9%E2%99%A5/")   # test_invalid_urls
                @test get(Client(), bad).status == 404
            end
            @test get(Client(), "/%ED").status == 404                                     # test_bad_path_info
        end

        @testset "TransactionsPerRequestTests" begin
            @test text(get(Client(), "/dhn/txn/")) == "autocommit"                        # test_no_auto_transaction
            override_settings(ATOMIC_REQUESTS = true) do
                @test text(get(Client(), "/dhn/txn/")) == "in a transaction"              # test_auto_transaction
                @test text(get(Client(), "/dhn/notxn/")) == "autocommit"                  # test_no_transaction (non_atomic_requests)
            end
        end

        @testset "SignalsTests" begin
            started, finished = Ref(0), Ref(0)                                            # test_request_signals
            on_start(sender; kw...) = (started[] += 1)
            on_finish(sender; kw...) = (finished[] += 1)
            connect!(request_started, on_start); connect!(request_finished, on_finish)
            try
                r = get(Client(), "/dhn/regular/")
                @test text(r) == "regular content" && started[] == 1 && finished[] == 1
                get(Client(), "/no/such/page/")                                           # (also for a 404)
                @test started[] == 2 && finished[] == 2
            finally
                disconnect!(request_started, on_start); disconnect!(request_finished, on_finish)
            end
        end

        @testset "HandlerRequestTests" begin
            r = get(Client(), "/dhn/bad/")                                                # test_bad_request_in_view_returns_400
            @test r.status == 400
            e = try get(Client(; raise_request_exception = true), "/dhn/none/") catch e; e end   # test_no_response
            @test e isa ErrorException && e.msg == "The view Main.dhn_none didn't return an HttpResponse object. It returned nothing instead."
            @test get(Client(), "/dhn/none/").status == 500
            returns_none(get_response) = nothing                                          # test_middleware_returns_none
            configure!(MIDDLEWARE = vcat(old[2], Any[returns_none]))
            e = try get(Client(; raise_request_exception = true), "/dhn/regular/") catch e; e end
            @test e isa Juango.ImproperlyConfigured && occursin("returned None", e.msg)
            not_used(get_response) = throw(Juango.MiddlewareNotUsed())                    # test_middleware_not_used
            configure!(MIDDLEWARE = vcat(old[2], Any[not_used]))
            @test text(get(Client(), "/dhn/regular/")) == "regular content"
            configure!(MIDDLEWARE = old[2])
        end
    finally
        configure!(ROOT_URLCONF = old[1], MIDDLEWARE = old[2])
    end
end
