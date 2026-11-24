# Django's generic_relations_regress, xor_lookups and managers_regress tests, translated (#227).
#
# Not translated: managers_regress's swappable-model and manager-inheritance (TestManagerInheritance) tests, which are
# about Python's class machinery (Juango's managers are functions and default_queryset methods), and
# generic_relations_regress's test_editable_generic_rel (a GenericRelation subclass overriding save_form_data).

# --- tests/generic_relations_regress/models.py ---------------------------------------------------------
@model struct DgrLink
    content_type = ForeignKey(ContentType; on_delete = :CASCADE)
    object_id = PositiveIntegerField()
    content_object = GenericForeignKey()
    Meta(table = "dgr_link")
end
@model struct DgrLinkProxy <: DgrLink
    Meta(proxy = true)
end
@model struct DgrPlace
    name = CharField(max_length = 100, default = "")
    links = GenericRelation(:DgrLink; related_query_name = "places")
    link_proxy = GenericRelation(:DgrLinkProxy)
    Meta(table = "dgr_place")
end
@model struct DgrRestaurant <: DgrPlace
    Meta(table = "dgr_restaurant")
end
@model struct DgrCafe <: DgrRestaurant
    Meta(table = "dgr_cafe")
end
@model struct DgrAddress
    street = CharField(max_length = 80)
    city = CharField(max_length = 50)
    state = CharField(max_length = 2)
    zipcode = CharField(max_length = 5)
    content_type = ForeignKey(ContentType; on_delete = :CASCADE)
    object_id = PositiveIntegerField()
    content_object = GenericForeignKey()
    Meta(table = "dgr_address")
end
@model struct DgrPerson
    account = IntegerField(primary_key = true)
    name = CharField(max_length = 128)
    addresses = GenericRelation(:DgrAddress)
    Meta(table = "dgr_person")
end
@model struct DgrCharLink
    content_type = ForeignKey(ContentType; on_delete = :CASCADE)
    object_id = CharField(max_length = 100)
    content_object = GenericForeignKey()
    value = CharField(max_length = 250, default = "")
    Meta(table = "dgr_charlink")
end
@model struct DgrTextLink
    content_type = ForeignKey(ContentType; on_delete = :CASCADE)
    object_id = TextField()
    content_object = GenericForeignKey()
    value = CharField(max_length = 250, default = "")
    Meta(table = "dgr_textlink")
end
@model struct DgrOddRelation1
    name = CharField(max_length = 100)
    clinks = GenericRelation(:DgrCharLink)
    Meta(table = "dgr_oddrelation1")
end
@model struct DgrOddRelation2
    name = CharField(max_length = 100)
    tlinks = GenericRelation(:DgrTextLink)
    Meta(table = "dgr_oddrelation2")
end
@model struct DgrNote
    content_type = ForeignKey(ContentType; on_delete = :CASCADE)
    object_id = PositiveIntegerField()
    content_object = GenericForeignKey()
    note = TextField()
    Meta(table = "dgr_note")
end
@model struct DgrContact
    notes = GenericRelation(:DgrNote)
    Meta(table = "dgr_contact")
end
@model struct DgrOrganization
    name = CharField(max_length = 255)
    contacts = ManyToManyField(DgrContact; related_name = "organizations")
    Meta(table = "dgr_organization")
end
@model struct DgrCompany
    name = CharField(max_length = 100)
    links = GenericRelation(:DgrLink)
    Meta(table = "dgr_company")
end
@model struct DgrTeam
    name = CharField(max_length = 15)
    Meta(table = "dgr_team")
end
@model struct DgrTag
    content_type = ForeignKey(ContentType; on_delete = :CASCADE, related_name = "g_r_r_tags")
    object_id = CharField(max_length = 15)
    content_object = GenericForeignKey()
    label = CharField(max_length = 15)
    Meta(table = "dgr_tag")
end
@model struct DgrBoard
    name = CharField(primary_key = true, max_length = 25)
    Meta(table = "dgr_board")
end
@abstract_model struct DgrHasLinks
    links = GenericRelation(:DgrLink; related_query_name = "targets")
end
@model struct DgrHasLinkThing <: DgrHasLinks
    Meta(table = "dgr_haslinkthing")
end
@model struct DgrA
    flag = BooleanField(null = true)
    content_type = ForeignKey(ContentType; on_delete = :CASCADE)
    object_id = PositiveIntegerField()
    content_object = GenericForeignKey(:content_type, :object_id)
    Meta(table = "dgr_a")
end
@model struct DgrB
    a = GenericRelation(:DgrA)
    Meta(table = "dgr_b", ordering = ["id"])
end
@model struct DgrC
    b = ForeignKey(DgrB; on_delete = :CASCADE)
    Meta(table = "dgr_c", ordering = ["id"])
end
@model struct DgrD
    b = ForeignKey(DgrB; on_delete = :SET_NULL, null = true)
    Meta(table = "dgr_d", ordering = ["id"])
end
@model struct DgrRelated
    Meta(table = "dgr_related")
end
@model struct DgrNode
    content_type = ForeignKey(ContentType; on_delete = :CASCADE)
    object_id = PositiveIntegerField()
    content = GenericForeignKey(:content_type, :object_id)
    Meta(table = "dgr_node")
end
@model struct DgrContent
    nodes = GenericRelation(:DgrNode)
    related_obj = ForeignKey(DgrRelated; on_delete = :CASCADE)
    Meta(table = "dgr_content")
end

# --- tests/xor_lookups/models.py ------------------------------------------------------------------------
@model struct DxlNumber
    num = IntegerField()
    Meta(table = "dxl_number")
end

# --- tests/managers_regress/models.py -------------------------------------------------------------------
# Django's managers are attributes; Juango's default manager is default_queryset and the others are functions
@abstract_model struct DmrAbstractBase1
    name = CharField(max_length = 50)
end
@abstract_model struct DmrAbstractBase2
    value = IntegerField()
end
@abstract_model struct DmrAbstractBase3
    comment = CharField(max_length = 50)
end
dmr_only_fred(T) = filter(base_objects(T); name = "fred")          # OnlyFred
dmr_only_barney(T) = filter(base_objects(T); name = "barney")      # OnlyBarney
dmr_value42(T) = filter(base_objects(T); value = 42)               # Value42
@model struct DmrParent
    name = CharField(max_length = 50)
    Meta(table = "dmr_parent")
end
@model struct DmrChild1 <: DmrAbstractBase1
    data = CharField(max_length = 25)
    Meta(table = "dmr_child1")
end
@model struct DmrChild2 <: DmrAbstractBase1
    value = IntegerField()                                         # (AbstractBase2's: one abstract base in Julia)
    data = CharField(max_length = 25)
    Meta(table = "dmr_child2")
end
@model struct DmrChild3 <: DmrAbstractBase1
    comment = CharField(max_length = 50)
    data = CharField(max_length = 25)
    Meta(table = "dmr_child3")
end
@model struct DmrChild4 <: DmrAbstractBase1
    data = CharField(max_length = 25)
    Meta(table = "dmr_child4")
end
@model struct DmrChild5 <: DmrAbstractBase3
    name = CharField(max_length = 25)
    Meta(table = "dmr_child5")
end
@model struct DmrChild6 <: DmrChild4
    value = IntegerField()
    Meta(table = "dmr_child6")
end
@model struct DmrChild7 <: DmrParent
    Meta(table = "dmr_child7")
end
# the first manager in the MRO is the default: OnlyFred for AbstractBase1's children, but not Child4 (its own
# models.Manager()) nor, as Child6 inherits it, Child6; Child5's `default = OnlyFred()`
Juango.default_queryset(::Type{T}) where {T<:Union{DmrChild1,DmrChild2,DmrChild3,DmrChild5}} = dmr_only_fred(T)
@model struct DmrRelatedModel
    test_gfk = GenericRelation(:DmrRelationModel; content_type_field = :gfk_ctype, object_id_field = :gfk_id)
    exact = BooleanField(null = true)
    Meta(table = "dmr_relatedmodel")
end
@model struct DmrRelationModel
    fk = ForeignKey(DmrRelatedModel; on_delete = :CASCADE, related_name = "test_fk")
    m2m = ManyToManyField(DmrRelatedModel; related_name = "test_m2m")
    gfk_ctype = ForeignKey(ContentType; on_delete = :SET_NULL, null = true)
    gfk_id = IntegerField(null = true)
    gfk = GenericForeignKey(:gfk_ctype, :gfk_id)
    Meta(table = "dmr_relationmodel")
end
Base.string(r::DmrRelationModel) = string(r.pk)

redirect_stdout(devnull) do
    ms = Any[DgrLink, DgrPlace, DgrRestaurant, DgrCafe, DgrAddress, DgrPerson, DgrCharLink, DgrTextLink, DgrOddRelation1,
             DgrOddRelation2, DgrNote, DgrContact, DgrOrganization, through(DgrOrganization, :contacts), DgrCompany, DgrTeam,
             DgrTag, DgrBoard, DgrHasLinkThing, DgrA, DgrB, DgrC, DgrD, DgrRelated, DgrNode, DgrContent,
             DxlNumber,
             DmrParent, DmrChild1, DmrChild2, DmrChild3, DmrChild4, DmrChild5, DmrChild6, DmrChild7, DmrRelatedModel,
             DmrRelationModel, through(DmrRelationModel, :m2m)]
    Juango.sync_models!(ms); append!(PORT_MODELS, ms)
end

dgr_pks(qs) = [x.pk for x in collect(qs)]

@testset "django generic_relations_regress: GenericRelationTests" begin
    port_block() do
        # test_inherited_models_content_type
        p = create(DgrPlace; name = "South Park"); r = create(DgrRestaurant; name = "Chubby's")
        l1 = create(DgrLink; content_object = p); l2 = create(DgrLink; content_object = r)
        @test dgr_pks(p.links) == [l1.pk]
        @test dgr_pks(r.links) == [l2.pk]
        # test_reverse_relation_pk
        pe = create(DgrPerson; account = 23, name = "Chef")
        create(DgrAddress; street = "123 Anywhere Place", city = "Conifer", state = "CO", zipcode = "80433", content_object = pe)
        qs = filter(DgrPerson; addresses__zipcode = "80433")
        @test count(qs) == 1 && first(qs).name == "Chef"
        # test_charlink_delete / test_textlink_delete
        o1 = create(DgrOddRelation1; name = "clink"); create(DgrCharLink; content_object = o1)
        delete!(o1); @test count(objects(DgrCharLink)) == 0
        o2 = create(DgrOddRelation2; name = "tlink"); create(DgrTextLink; content_object = o2)
        delete!(o2); @test count(objects(DgrTextLink)) == 0
        # test_charlink_filter / test_textlink_filter
        o1 = create(DgrOddRelation1; name = "clink"); create(DgrCharLink; content_object = o1, value = "value")
        @test dgr_pks(filter(DgrOddRelation1; clinks__value = "value")) == [o1.pk]
        o2 = create(DgrOddRelation2; name = "clink"); create(DgrTextLink; content_object = o2, value = "value")
        @test dgr_pks(filter(DgrOddRelation2; tlinks__value = "value")) == [o2.pk]
        # test_coerce_object_id_remote_field_cache_persistence
        rest = create(DgrRestaurant)
        create(DgrCharLink; content_object = rest)
        cl = latest(objects(DgrCharLink), "pk")
        @test cl.content_object === cl.content_object
        @test cl.content_object.pk == rest.pk
        cafe = create(DgrCafe)
        create(DgrCharLink; content_object = cafe)
        cl = latest(objects(DgrCharLink), "pk")
        @test cl.content_object === cl.content_object && cl.content_object.pk == cafe.pk
        # test_q_object_or
        note_contact = create(DgrContact); org_contact = create(DgrContact)
        create(DgrNote; note = "note", content_object = note_contact)
        org = create(DgrOrganization; name = "org name"); add!(org.contacts, org_contact)
        @test org_contact.pk in dgr_pks(filter(DgrContact, Q(notes__note__icontains = "other note") | Q(organizations__name__icontains = "org name")))
        @test org_contact.pk in dgr_pks(filter(DgrContact, Q(organizations__name__icontains = "org name") | Q(notes__note__icontains = "other note")))
        # test_join_reuse
        @test count("JOIN", first(Juango.select_sql(filter(filter(DgrPerson; addresses__street = "foo"); addresses__street = "bar")))) == 2
        # test_generic_relation_ordering
        delete!(objects(DgrLink)); delete!(objects(DgrPlace))
        p1 = create(DgrPlace; name = "South Park"); p2 = create(DgrPlace; name = "The City")
        c = create(DgrCompany; name = "Chubby's Intl.")
        create(DgrLink; content_object = p1); create(DgrLink; content_object = c)
        places = collect(order_by(objects(DgrPlace), "links__id"))
        @test length(places) == 2 && count(x -> x.pk == p1.pk, places) == 1 && count(x -> x.pk == p2.pk, places) == 1
        # test_target_model_len_zero / test_target_model_bool_false (Python's __len__ and __bool__: a plain target)
        team1 = create(DgrTeam; name = "Backend devs")
        n = DgrNote(; note = "Deserve a bonus", content_object = team1); save!(n)
        @test get(DgrNote; pk = n.pk).content_object.pk == team1.pk
        # test_gfk_to_model_with_empty_pk
        b1 = create(DgrBoard; name = "")
        tag = DgrTag(; label = "VP", content_object = b1); save!(tag)
        @test get(DgrTag; pk = tag.pk).object_id == ""
        # test_filter_on_related_proxy_model
        place = create(DgrPlace)
        create(DgrLink; content_object = place)
        @test get(DgrPlace; link_proxy__object_id = place.id).pk == place.pk
        # test_generic_reverse_relation_with_mti
        delete!(objects(DgrLink))
        place = create(DgrPlace; name = "Test Place")
        link = create(DgrLink; content_object = place)
        @test dgr_pks(filter(DgrLink; places = place)) == [link.pk]
        # test_generic_reverse_relation_exclude_filter
        delete!(objects(DgrLink)); delete!(objects(DgrPlace))
        place1 = create(DgrPlace; name = "Test Place 1"); place2 = create(DgrPlace; name = "Test Place 2")
        create(DgrLink; content_object = place1); link2 = create(DgrLink; content_object = place2)
        @test dgr_pks(filter(DgrLink, ~Q(places__name = "Test Place 1"))) == [link2.pk]
        @test dgr_pks(exclude(DgrLink; places__name = "Test Place 1")) == [link2.pk]
        # test_check_cached_value_pk_different_type
        board = create(DgrBoard; name = "some test")
        oddrel = create(DgrOddRelation1; name = "clink")
        cl = create(DgrCharLink; content_object = oddrel)
        cl = get(DgrCharLink; pk = cl.pk)
        @test cl.content_object.pk == oddrel.pk && cl.content_object isa DgrOddRelation1
        cl.object_id = board.pk
        cl.content_type_id = get_for_model(DgrBoard).id
        @test cl.content_object isa DgrBoard && cl.content_object.pk == board.pk
        # (test_ticket_22982: the related manager's class name in its repr; Juango's is a QuerySet)
    end
    port_block() do
        # test_ticket_20378
        hs = [create(DgrHasLinkThing) for _ in 1:4]
        l1 = create(DgrLink; content_object = hs[3]); l2 = create(DgrLink; content_object = hs[4])
        @test dgr_pks(filter(DgrHasLinkThing; links = l1)) == [hs[3].pk]
        @test dgr_pks(filter(DgrHasLinkThing; links = l2)) == [hs[4].pk]
        @test dgr_pks(order_by(exclude(DgrHasLinkThing; links = l2), "pk")) == [hs[1].pk, hs[2].pk, hs[3].pk]
        @test dgr_pks(order_by(exclude(DgrHasLinkThing; links = l1), "pk")) == [hs[1].pk, hs[2].pk, hs[4].pk]
        # test_generic_reverse_relation_with_abc
        thing = create(DgrHasLinkThing)
        link = create(DgrLink; content_object = thing)
        @test dgr_pks(link.targets) == [thing.pk]
    end
    port_block() do
        # test_ticket_20564
        b1, b2, b3 = create(DgrB), create(DgrB), create(DgrB)
        c1, c2, c3 = create(DgrC; b = b1), create(DgrC; b = b2), create(DgrC; b = b3)
        create(DgrA; flag = nothing, content_object = b1); create(DgrA; flag = true, content_object = b2)
        @test dgr_pks(filter(DgrC; b__a__flag = nothing)) == [c1.pk, c3.pk]
        @test dgr_pks(exclude(DgrC; b__a__flag = nothing)) == [c2.pk]
    end
    port_block() do
        # test_ticket_20564_nullable_fk
        b1, b2, b3 = create(DgrB), create(DgrB), create(DgrB)
        d1, d2, d3, d4 = create(DgrD; b = b1), create(DgrD; b = b2), create(DgrD; b = b3), create(DgrD)
        create(DgrA; flag = nothing, content_object = b1); create(DgrA; flag = true, content_object = b1)
        create(DgrA; flag = true, content_object = b2)
        @test dgr_pks(exclude(DgrD; b__a__flag = nothing)) == [d2.pk]
        @test dgr_pks(filter(DgrD; b__a__flag = nothing)) == [d1.pk, d3.pk, d4.pk]
        @test dgr_pks(filter(DgrB; a__flag = nothing)) == [b1.pk, b3.pk]
        @test dgr_pks(exclude(DgrB; a__flag = nothing)) == [b2.pk]
        # test_extra_join_condition
        @test occursin("content_type_id", lowercase(first(Juango.select_sql(exclude(DgrB; a__flag = nothing)))))
        @test occursin("content_type_id", lowercase(first(Juango.select_sql(exclude(DgrB; a__flag = true)))))
    end
    port_block() do
        # test_annotate
        hs1, hs2, _ = create(DgrHasLinkThing), create(DgrHasLinkThing), create(DgrHasLinkThing)
        b = create(DgrBoard; name = string(hs1.pk))
        create(DgrLink; content_object = hs2)
        link = create(DgrLink; content_object = hs1)
        create(DgrLink; content_object = b)
        qs = filter(annotate(objects(DgrHasLinkThing), Sum(:links)); pk = hs1.pk)
        @test count(qs) == 1
        @test first(qs).links__sum == link.id
        delete!(link)
        @test count(qs) == 1
        @test first(qs).links__sum === nothing
        @test count(filter(qs; links__sum__isnull = true)) == 1
        @test count(filter(qs; links__sum__isnull = false)) == 0
    end
    port_block() do
        # test_filter_targets_related_pk
        create(DgrHasLinkThing; id = 1); hs2 = create(DgrHasLinkThing; id = 2)
        link = create(DgrLink; content_object = hs2, id = 1)
        @test link.object_id != link.pk
        @test dgr_pks(filter(DgrHasLinkThing; links = link.pk)) == [hs2.pk]
    end
    port_block() do
        # test_ticket_22998: deleting the Related cascades to the Content, then to the Node, whose pre_delete refuses
        prevent = (sender; instance, kw...) -> throw(ProtectedError("Not allowed to delete.", [instance], DgrNode))
        connect!(pre_delete, prevent; sender = DgrNode, dispatch_uid = :dgr_prevent_deletes)
        try
            related = create(DgrRelated)
            content = create(DgrContent; related_obj = related)
            create(DgrNode; content = content)
            @test_throws ProtectedError delete!(related)
        finally
            disconnect!(pre_delete; sender = DgrNode, dispatch_uid = :dgr_prevent_deletes)
        end
    end
end

@testset "django xor_lookups: XorLookupsTests" begin
    port_block() do
        ns = [create(DxlNumber; num = i) for i in 0:9]
        pks(qs) = sort(dgr_pks(qs))
        want(r) = sort([ns[i+1].pk for i in r])
        N = objects(DxlNumber)
        # test_filter
        @test pks(xor(filter(N; num__lte = 7), filter(N; num__gte = 3))) == want([0, 1, 2, 8, 9])
        @test pks(filter(N, Q(num__lte = 7) ⊻ Q(num__gte = 3))) == want([0, 1, 2, 8, 9])
        # test_filter_multiple
        qs = filter(N, xor(Q(num__gte = 1), Q(num__gte = 3), Q(num__gte = 5), Q(num__gte = 7), Q(num__gte = 9)))
        @test pks(qs) == want([1, 2, 5, 6, 9])
        @test sort(collect(values_list(qs, :num; flat = true))) ==
              [i for i in 0:9 if xor(i >= 1, i >= 3, i >= 5, i >= 7, i >= 9)]
        # test_filter_negated
        @test pks(filter(N, Q(num__lte = 7) ⊻ ~Q(num__lt = 3))) == want([0, 1, 2, 8, 9])
        @test pks(filter(N, ~Q(num__gt = 7) ⊻ ~Q(num__lt = 3))) == want([0, 1, 2, 8, 9])
        @test pks(filter(N, xor(Q(num__lte = 7), ~Q(num__lt = 3), Q(num__lte = 1)))) == want([2, 8, 9])
        @test pks(filter(N, ~xor(Q(num__lte = 7), ~Q(num__lt = 3), Q(num__lte = 1)))) == want([0, 1, 3, 4, 5, 6, 7])
        # test_exclude
        @test pks(exclude(N, Q(num__lte = 7) ⊻ Q(num__gte = 3))) == want(3:7)
        # test_stages
        @test isempty(collect(xor(filter(N; num__gte = 0), filter(N; num__lte = 11))))
        @test dgr_pks(xor(filter(N; num__gt = 0), filter(N; num__lt = 11))) == [ns[1].pk]
        # test_pk_q
        @test pks(filter(N, Q(pk = ns[1].pk) ⊻ Q(pk = ns[2].pk))) == want([0, 1])
        # test_empty_in
        @test pks(filter(N, Q(pk__in = Int[]) ⊻ Q(num__gte = 5))) == want(5:9)
    end
end

@testset "django managers_regress: ManagersRegressionTests" begin
    port_block() do
        # test_managers
        a1 = create(DmrChild1; name = "fred", data = "a1"); a2 = create(DmrChild1; name = "barney", data = "a2")
        b1 = create(DmrChild2; name = "fred", data = "b1", value = 1); b2 = create(DmrChild2; name = "barney", data = "b2", value = 42)
        c1 = create(DmrChild3; name = "fred", data = "c1", comment = "yes"); c2 = create(DmrChild3; name = "barney", data = "c2", comment = "no")
        d1 = create(DmrChild4; name = "fred", data = "d1"); d2 = create(DmrChild4; name = "barney", data = "d2")
        fred1 = create(DmrChild5; name = "fred", comment = "yes"); create(DmrChild5; name = "barney", comment = "no")
        f1 = create(DmrChild6; name = "fred", data = "f1", value = 42); f2 = create(DmrChild6; name = "barney", data = "f2", value = 42)
        fred2 = create(DmrChild7; name = "fred"); barney = create(DmrChild7; name = "barney")
        @test dgr_pks(dmr_only_fred(DmrChild1)) == [a1.pk]
        @test dgr_pks(dmr_only_barney(DmrChild1)) == [a2.pk]
        @test dgr_pks(objects(DmrChild1)) == [a1.pk]
        @test dgr_pks(objects(DmrChild2)) == [b1.pk]
        @test dgr_pks(dmr_value42(DmrChild2)) == [b2.pk]
        @test dgr_pks(objects(DmrChild3)) == [c1.pk]
        @test dgr_pks(dmr_only_fred(DmrChild3)) == [c1.pk] && dgr_pks(dmr_only_barney(DmrChild3)) == [c2.pk]
        # (Child6's rows are Child4 rows too)
        @test dgr_pks(order_by(objects(DmrChild4), "data")) == [d1.pk, d2.pk, f1.pk, f2.pk]
        @test sort(dgr_pks(dmr_only_fred(DmrChild4))) == sort([d1.pk, f1.pk])
        @test dgr_pks(objects(DmrChild5)) == [fred1.pk]
        @test sort(dgr_pks(objects(DmrChild6))) == sort([f1.pk, f2.pk])
        @test dgr_pks(order_by(objects(DmrChild7), "name")) == [barney.pk, fred2.pk]
        # test_abstract_manager / test_custom_abstract_manager / test_explicit_abstract_manager: an abstract model has
        # no rows to query
        @test_throws "Manager isn't available; DmrAbstractBase3 is abstract" objects(DmrAbstractBase3)
    end
    port_block() do
        # test_regress_3871: related managers in templates
        related = create(DmrRelatedModel)
        relation = DmrRelationModel()
        relation.fk = related
        relation.gfk = related
        save!(relation)
        add!(relation.m2m, related)
        t = Template("{{ related.test_fk.all.0 }}{{ related.test_gfk.all.0 }}{{ related.test_m2m.all.0 }}")
        @test render(t, Dict("related" => related)) == string(relation.pk)^3
        # test_field_can_be_called_exact
        related = create(DmrRelatedModel; exact = false)
        relation = create(related.test_fk)
        @test get(related.test_fk).pk == relation.pk
    end
end
