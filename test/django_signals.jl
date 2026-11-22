# Django's signal tests, ported (#227): tests/dispatch (DispatcherTests, ReceiverTestCase) and
# tests/signals (SignalTests).
# julia --project=test test/django_signals.jl   (see setup.jl)
#
# Juango's receivers are called as `receiver(sender; signal, kwargs...)`; `send` returns
# `receiver => result` pairs (Django: tuples). Django keeps weak references to receivers by default;
# Juango keeps them alive until disconnected, so the garbage-collection tests aren't translated.
# Each test keeps its Django name in a comment.
@isdefined(TEST_SETUP_DONE) || include("setup.jl")

@model struct DsgPerson
    first_name = CharField(max_length = 20)
    last_name = CharField(max_length = 20)
    Meta(table = "dsg_person")
end
@model struct DsgCar
    make = CharField(max_length = 20)
    model = CharField(max_length = 20)
    Meta(table = "dsg_car")
end
@model struct DsgAuthor
    name = CharField(max_length = 20)
    Meta(table = "dsg_author")
end
@model struct DsgBook
    name = CharField(max_length = 20)
    authors = ManyToManyField(DsgAuthor; blank = true)
    Meta(table = "dsg_book")
end
@model struct DsgPage
    book = ForeignKey(DsgBook; on_delete = :CASCADE)
    text = TextField(default = "")
    Meta(table = "dsg_page")
end
redirect_stdout(devnull) do
    Juango.sync_models!([DsgPerson, DsgCar, DsgAuthor, DsgBook, through(DsgBook, :authors), DsgPage])
    append!(PORT_MODELS, [DsgPerson, DsgCar, DsgAuthor, DsgBook, through(DsgBook, :authors), DsgPage])
end

dsp_receiver_1(sender; val = nothing, kw...) = val
dsp_clean(sigs...) = all(s -> !Juango.any_receivers(s), sigs)

@testset "django dispatch: DispatcherTests" begin
    a_signal, b_signal, c_signal = Signal("a"), Signal("b"), Signal("c")
    connect!(a_signal, dsp_receiver_1)                                                   # test_send
    @test send(a_signal, :me; val = "test") == [dsp_receiver_1 => "test"]
    @test disconnect!(a_signal, dsp_receiver_1)
    @test dsp_clean(a_signal)
    @test send(a_signal, :me; val = "test") == []                                        # test_send_no_receivers
    connect!(a_signal, dsp_receiver_1; sender = :me)                                     # test_send_connected_no_sender
    @test send(a_signal, :me; val = "test") == [dsp_receiver_1 => "test"]
    @test send(a_signal, :other; val = "test") == []                                     # test_send_different_no_sender
    disconnect!(a_signal, dsp_receiver_1; sender = :me)
    @test dsp_clean(a_signal)
    connect!(a_signal, dsp_receiver_1)                                                   # test_send (sender None: any sender)
    @test send(a_signal, DsgPerson; val = 1) == [dsp_receiver_1 => 1]
    disconnect!(a_signal, dsp_receiver_1)

    r1(sender; kw...) = 1                                                                # test_uid_registration
    r2(sender; kw...) = 2
    connect!(a_signal, r1; dispatch_uid = "uid")
    connect!(a_signal, r2; dispatch_uid = "uid")
    @test length(a_signal.receivers) == 1
    disconnect!(a_signal; dispatch_uid = "uid")
    @test dsp_clean(a_signal)
    connect!(a_signal, dsp_receiver_1); connect!(a_signal, dsp_receiver_1)               # (the same receiver twice: once)
    @test length(a_signal.receivers) == 1
    disconnect!(a_signal, dsp_receiver_1)

    connect!(a_signal, dsp_receiver_1)                                                   # test_send_robust_success
    @test send_robust(a_signal, :me; val = "test") == [dsp_receiver_1 => "test"]
    disconnect!(a_signal, dsp_receiver_1)
    @test send_robust(a_signal, :me; val = "test") == []                                 # test_send_robust_no_receivers
    connect!(a_signal, dsp_receiver_1; sender = :me)                                     # test_send_robust_ignored_sender
    @test send_robust(a_signal, :other; val = "test") == []
    disconnect!(a_signal, dsp_receiver_1; sender = :me)
    fails(sender; kw...) = throw(ArgumentError("I failed"))                              # test_send_robust_fail
    connect!(a_signal, fails)
    mem = MemoryHandler()
    res = override_settings(LOGGING = Dict("handlers" => Dict("mem" => Dict("class" => mem)),
                                           "loggers" => Dict("juango.dispatch" => Dict("handlers" => ["mem"], "level" => "ERROR", "propagate" => false)))) do
        send_robust(a_signal, :me; val = "test")
    end
    @test length(res) == 1 && res[1].first === fails && res[1].second isa ArgumentError && res[1].second.msg == "I failed"
    rec = only(mem.records)
    @test rec.name == "juango.dispatch" && rec.level == 40 && occursin("in Signal.send_robust() (ArgumentError: I failed)", rec.message)
    @test rec.exception !== nothing && rec.exception[1] === res[1].second
    @test_throws ArgumentError send(a_signal, :me)                                       # (send: the exception propagates)
    disconnect!(a_signal, fails)
    @test dsp_clean(a_signal)

    ra(sender; kw...) = "a"; rb(sender; kw...) = "b"; rc(sender; kw...) = "c"            # test_disconnection
    foreach(r -> connect!(a_signal, r), (ra, rb, rc))
    disconnect!(a_signal, rb)
    @test [p.first for p in send(a_signal, :me)] == [ra, rc]
    disconnect!(a_signal, ra); disconnect!(a_signal, rc)
    @test dsp_clean(a_signal)
    connect!(a_signal, ra)                                                               # test_values_returned_by_disconnection
    @test disconnect!(a_signal, ra) == true
    @test disconnect!(a_signal, ra) == false
    @test disconnect!(a_signal, rb) == false
    @test !Juango.any_receivers(a_signal)                                                # test_has_listeners
    @test !has_receivers(a_signal, :me)
    connect!(a_signal, ra)
    @test Juango.any_receivers(a_signal) && has_receivers(a_signal, :me) && has_receivers(a_signal, :other)
    disconnect!(a_signal, ra)
    connect!(a_signal, ra; sender = :me)
    @test has_receivers(a_signal, :me) && !has_receivers(a_signal, :other)
    disconnect!(a_signal, ra; sender = :me)
    @test dsp_clean(a_signal, b_signal, c_signal)
end

@testset "django dispatch: ReceiverTestCase" begin
    a_signal, b_signal, c_signal = Signal("a"), Signal("b"), Signal("c")
    state = Ref{Any}(nothing)                                                            # test_receiver_single_signal
    f = receiver(a_signal) do sender, args
        state[] = args.val
    end
    send(a_signal, :me; val = true)
    @test state[] === true
    disconnect!(a_signal; dispatch_uid = objectid(f))
    @test dsp_clean(a_signal)
    seen = String[]                                                                      # test_receiver_signal_list
    g = receiver([a_signal, b_signal, c_signal]) do sender, args
        push!(seen, args.signal.name)
    end
    send(a_signal, :me); send(b_signal, :me); send(c_signal, :me)
    @test seen == ["a", "b", "c"]
    foreach(s -> disconnect!(s; dispatch_uid = objectid(g)), (a_signal, b_signal, c_signal))
    @test dsp_clean(a_signal, b_signal, c_signal)
end

@testset "django signals: SignalTests" begin
    port_block() do
        data = Any[]
        pre_init_r(sender; kwargs, kw...) = push!(data, (sender, kwargs))                # test_model_pre_init_and_post_init
        post_init_r(sender; instance, kw...) = push!(data, instance)
        connect!(pre_init, pre_init_r; sender = DsgPerson)
        connect!(post_init, post_init_r; sender = DsgPerson)
        try
            p = DsgPerson(first_name = "John", last_name = "Doe")
            @test data[1] == (DsgPerson, Dict{Symbol,Any}(:first_name => "John", :last_name => "Doe")) && data[2] === p
        finally
            disconnect!(pre_init, pre_init_r; sender = DsgPerson); disconnect!(post_init, post_init_r; sender = DsgPerson)
        end

        empty!(data)                                                                     # test_save_signals
        pre_save_h(sender; instance, created, update_fields = nothing, kw...) = push!(data, (:pre, instance.first_name, created, update_fields))
        post_save_h(sender; instance, created, update_fields = nothing, kw...) = push!(data, (:post, instance.first_name, created, update_fields))
        connect!(pre_save, pre_save_h; sender = DsgPerson); connect!(post_save, post_save_h; sender = DsgPerson)
        try
            p1 = save!(DsgPerson(first_name = "John", last_name = "Smith"))
            @test data == [(:pre, "John", true, nothing), (:post, "John", true, nothing)]
            empty!(data)
            p1.first_name = "Tom"; save!(p1)
            @test data == [(:pre, "Tom", false, nothing), (:post, "Tom", false, nothing)]
            empty!(data)
            p1.first_name = "Will"; save!(p1; update_fields = [:first_name])
            @test data == [(:pre, "Will", false, Set([:first_name])), (:post, "Will", false, Set([:first_name]))]
            empty!(data)
            save!(DsgCar(make = "Volkswagen", model = "Passat"))                         # (another sender: not heard)
            @test isempty(data)
        finally
            disconnect!(pre_save, pre_save_h; sender = DsgPerson); disconnect!(post_save, post_save_h; sender = DsgPerson)
        end

        empty!(data)                                                                     # test_delete_signals
        pre_delete_h(sender; instance, origin = nothing, kw...) =
            push!(data, (:pre, instance.id, exists(filter(objects(DsgPerson); id = instance.id)), origin))
        post_delete_h(sender; instance, origin = nothing, kw...) =
            push!(data, (:post, instance.id, exists(filter(objects(DsgPerson); id = instance.id)), origin))
        connect!(pre_delete, pre_delete_h; sender = DsgPerson); connect!(post_delete, post_delete_h; sender = DsgPerson)
        try
            p1 = save!(DsgPerson(first_name = "John", last_name = "Smith"))
            id1 = p1.id
            delete!(p1)
            @test [d[1:3] for d in data] == [(:pre, id1, true), (:post, id1, false)]     # (the row still exists in pre_delete only)
            @test data[1][4] === p1 && data[2][4] === p1                                 # test_delete_signals_origin_model
            @test p1.id === nothing
            empty!(data)
            p2 = save!(DsgPerson(first_name = "James", last_name = "Jones"))
            qs = filter(objects(DsgPerson); id = p2.id)
            delete!(qs)
            @test length(data) == 2 && data[1][1:3] == (:pre, p2.id, true) && data[2][1:3] == (:post, p2.id, false)
            @test data[1][4] === qs && data[2][4] === qs                                 # test_delete_signals_origin_queryset
        finally
            disconnect!(pre_delete, pre_delete_h; sender = DsgPerson); disconnect!(post_delete, post_delete_h; sender = DsgPerson)
        end

        origins = Any[]                                                                  # test_delete_signals_origin_model
        orig_h(sender; instance, origin = nothing, kw...) = push!(origins, (sender, origin))
        for s in (pre_delete, post_delete), M in (DsgBook, DsgPage)
            connect!(s, orig_h; sender = M)
        end
        try
            b = save!(DsgBook(name = "Lord of the Rings"))
            save!(DsgPage(book = b, text = "one"))
            delete!(b)
            @test Set(first.(origins)) == Set([DsgBook, DsgPage]) && length(origins) == 4
            @test all(o -> o[2] === b, origins)                                          # (the cascaded page's origin: the book)
            empty!(origins)
            b2 = save!(DsgBook(name = "Hobbit")); save!(DsgPage(book = b2))
            qs = filter(objects(DsgBook); name = "Hobbit")
            delete!(qs)
            @test length(origins) == 4 && all(o -> o[2] === qs, origins)
        finally
            for s in (pre_delete, post_delete), M in (DsgBook, DsgPage)
                disconnect!(s, orig_h; sender = M)
            end
        end

        heard = Any[]                                                                    # test_decorators
        h = receiver(post_save; sender = DsgCar) do sender, args
            push!(heard, (sender, args.created))
        end
        try
            save!(DsgCar(make = "Ford", model = "Ka"))
            @test heard == [(DsgCar, true)]
        finally
            disconnect!(post_save; sender = DsgCar, dispatch_uid = objectid(h))
        end

        m2m = Any[]                                                                      # test_save_and_delete_signals_with_m2m
        thr = through(DsgBook, :authors)
        m2m_h(sender; action, instance, model, pk_set, reverse, kw...) = push!(m2m, (action, instance.name, model, pk_set, reverse))
        connect!(m2m_changed, m2m_h; sender = thr)
        try
            a1 = save!(DsgAuthor(name = "Tolkien")); a2 = save!(DsgAuthor(name = "Lewis"))
            b = save!(DsgBook(name = "Inklings"))
            add!(b.authors, a1, a2)
            @test m2m == [(:pre_add, "Inklings", DsgAuthor, Set([a1.id, a2.id]), false), (:post_add, "Inklings", DsgAuthor, Set([a1.id, a2.id]), false)]
            empty!(m2m)
            remove!(b.authors, a2)
            @test m2m == [(:pre_remove, "Inklings", DsgAuthor, Set([a2.id]), false), (:post_remove, "Inklings", DsgAuthor, Set([a2.id]), false)]
            empty!(m2m)
            clear!(b.authors)
            @test [(x[1], x[4]) for x in m2m] == [(:pre_clear, nothing), (:post_clear, nothing)]
        finally
            disconnect!(m2m_changed, m2m_h; sender = thr)
        end

        calls = String[]                                                                 # test_disconnect_in_dispatch
        sig = Signal("dispatch")
        first_r(sender; kw...) = (push!(calls, "first"); disconnect!(sig, first_r))
        second_r(sender; kw...) = push!(calls, "second")
        connect!(sig, first_r); connect!(sig, second_r)
        send(sig, :me)
        @test calls == ["first", "second"]                                               # (both called; the first is gone after)
        send(sig, :me)
        @test calls == ["first", "second", "second"]
        disconnect!(sig, second_r)
    end
    # not translated: the `raw` and `using` arguments (no raw saves; `using` is a keyword in Julia), lazy
    # "app_label.Model" string senders, weak receivers, Signal(use_caching=true), the async receivers
end
