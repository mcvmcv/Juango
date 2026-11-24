# Django's model_formsets_regress tests, translated (#227).
#
# Not translated: FormfieldCallbackTests (widget classes and formfield_callback's call log: Python class
# mechanics), BaseCustomDeleteFormSet's _should_delete_form override, test_error_class (ErrorDict/ErrorList
# classes) and test_extraneous_query_is_not_run's query count.

# --- tests/model_formsets_regress/models.py ---------------------------------------------------------------
@model struct DmfrUser
    username = CharField(max_length = 12, unique = true)
    serial = IntegerField()
    Meta(table = "dmfr_user")
end
@model struct DmfrUserSite
    user = ForeignKey(DmfrUser; on_delete = :CASCADE, to_field = :username)
    data = IntegerField()
    Meta(table = "dmfr_usersite")
end
@model struct DmfrUserProfile
    user = ForeignKey(DmfrUser; on_delete = :CASCADE, unique = true, to_field = :username)
    about = TextField()
    Meta(table = "dmfr_userprofile")
end
@model struct DmfrUserPreferences
    user = OneToOneField(DmfrUser; on_delete = :CASCADE, to_field = :username, primary_key = true)
    favorite_number = IntegerField()
    Meta(table = "dmfr_userpreferences")
end
@model struct DmfrProfileNetwork
    profile = ForeignKey(DmfrUserProfile; on_delete = :CASCADE, to_field = :user)
    network = IntegerField()
    identifier = IntegerField()
    Meta(table = "dmfr_profilenetwork")
end
@model struct DmfrPlace
    name = CharField(max_length = 50)
    Meta(table = "dmfr_place")
end
@model struct DmfrRestaurant <: DmfrPlace
    Meta(table = "dmfr_restaurant")
end
@model struct DmfrManager
    restaurant = ForeignKey(DmfrRestaurant; on_delete = :CASCADE)
    name = CharField(max_length = 50)
    Meta(table = "dmfr_manager")
end
@model struct DmfrNetwork
    name = CharField(max_length = 15)
    Meta(table = "dmfr_network")
end
@model struct DmfrHost
    network = ForeignKey(DmfrNetwork; on_delete = :CASCADE)
    hostname = CharField(max_length = 25)
    Meta(table = "dmfr_host")
end

redirect_stdout(devnull) do
    ms = Any[DmfrUser, DmfrUserSite, DmfrUserProfile, DmfrUserPreferences, DmfrProfileNetwork, DmfrPlace, DmfrRestaurant,
             DmfrManager, DmfrNetwork, DmfrHost]
    Juango.sync_models!(ms); append!(PORT_MODELS, ms)
end

dmfr_rows(qs) = collect(values(qs))

@testset "django model_formsets_regress: InlineFormsetTests" begin
  port_block() do
    # test_formset_over_to_field
    Form = modelform_factory(DmfrUser; fields = "__all__")
    FormSet = inlineformset_factory(DmfrUser, DmfrUserSite; fields = "__all__")
    Form(); FormSet(; instance = DmfrUser(), prefix = "usersite_set")
    data = Dict("serial" => "1", "username" => "apollo13", "usersite_set-TOTAL_FORMS" => "1", "usersite_set-INITIAL_FORMS" => "0",
                "usersite_set-MAX_NUM_FORMS" => "0", "usersite_set-0-data" => "10", "usersite_set-0-user" => "apollo13")
    form = Form(data)
    @test is_valid(form)
    user = save!(form)
    fs = FormSet(data; instance = user, prefix = "usersite_set")
    @test is_valid(fs)
    save!(fs)
    us = dmfr_rows(objects(DmfrUserSite))
    @test us[1][:data] == 10 && us[1][:user_id] == "apollo13"
    data = Dict("usersite_set-TOTAL_FORMS" => "1", "usersite_set-INITIAL_FORMS" => "1", "usersite_set-MAX_NUM_FORMS" => "0",
                "usersite_set-0-id" => string(us[1][:id]), "usersite_set-0-data" => "11", "usersite_set-0-user" => "apollo13")
    fs = FormSet(data; instance = user, prefix = "usersite_set")
    @test is_valid(fs)
    save!(fs)
    us = dmfr_rows(objects(DmfrUserSite))
    @test us[1][:data] == 11 && us[1][:user_id] == "apollo13"
    data = Dict("usersite_set-TOTAL_FORMS" => "2", "usersite_set-INITIAL_FORMS" => "1", "usersite_set-MAX_NUM_FORMS" => "0",
                "usersite_set-0-id" => string(us[1][:id]), "usersite_set-0-data" => "11", "usersite_set-0-user" => "apollo13",
                "usersite_set-1-data" => "42", "usersite_set-1-user" => "apollo13")
    fs = FormSet(data; instance = user, prefix = "usersite_set")
    @test is_valid(fs)
    save!(fs)
    us = dmfr_rows(order_by(objects(DmfrUserSite), "data"))
    @test [(u[:data], u[:user_id]) for u in us] == [(11, "apollo13"), (42, "apollo13")]
  end
  port_block() do
    # test_formset_over_inherited_model
    Form = modelform_factory(DmfrRestaurant; fields = "__all__")
    FormSet = inlineformset_factory(DmfrRestaurant, DmfrManager; fields = "__all__")
    Form(); FormSet(; instance = DmfrRestaurant(), prefix = "manager_set")
    data = Dict("name" => "Guido's House of Pasta", "manager_set-TOTAL_FORMS" => "1", "manager_set-INITIAL_FORMS" => "0",
                "manager_set-MAX_NUM_FORMS" => "0", "manager_set-0-name" => "Guido Van Rossum")
    form = Form(data)
    @test is_valid(form)
    restaurant = save!(form)
    fs = FormSet(data; instance = restaurant, prefix = "manager_set")
    @test is_valid(fs)
    save!(fs)
    m = dmfr_rows(objects(DmfrManager))
    @test m[1][:name] == "Guido Van Rossum"
    data = Dict("manager_set-TOTAL_FORMS" => "1", "manager_set-INITIAL_FORMS" => "1", "manager_set-MAX_NUM_FORMS" => "0",
                "manager_set-0-id" => string(m[1][:id]), "manager_set-0-name" => "Terry Gilliam")
    fs = FormSet(data; instance = restaurant, prefix = "manager_set")
    @test is_valid(fs)
    save!(fs)
    m = dmfr_rows(objects(DmfrManager))
    @test m[1][:name] == "Terry Gilliam"
    data = Dict("manager_set-TOTAL_FORMS" => "2", "manager_set-INITIAL_FORMS" => "1", "manager_set-MAX_NUM_FORMS" => "0",
                "manager_set-0-id" => string(m[1][:id]), "manager_set-0-name" => "Terry Gilliam", "manager_set-1-name" => "John Cleese")
    fs = FormSet(data; instance = restaurant, prefix = "manager_set")
    @test is_valid(fs)
    save!(fs)
    @test [r[:name] for r in dmfr_rows(order_by(objects(DmfrManager), "name"))] == ["John Cleese", "Terry Gilliam"]
  end
  port_block() do
    # test_inline_model_with_to_field
    FormSet = inlineformset_factory(DmfrUser, DmfrUserSite; exclude = [:is_superuser])
    user = create(DmfrUser; username = "guido", serial = 1337)
    create(DmfrUserSite; user, data = 10)
    @test FormSet(; instance = user).forms[1].instance.user_id == "guido"
    # test_inline_model_with_primary_to_field
    FormSet = inlineformset_factory(DmfrUser, DmfrUserPreferences; exclude = [:is_superuser])
    create(DmfrUserPreferences; user, favorite_number = 10)
    @test FormSet(; instance = user).forms[1].initial[:user] == "guido"
  end
  port_block() do
    # test_inline_model_with_to_field_to_rel
    FormSet = inlineformset_factory(DmfrUserProfile, DmfrProfileNetwork; exclude = Symbol[])
    user = create(DmfrUser; username = "guido", serial = 1337, id = 1)
    profile = create(DmfrUserProfile; user, about = "about", id = 2)
    @test user.pk == 1 && profile.pk == 2
    create(DmfrProfileNetwork; profile, network = 10, identifier = 10)
    # (Django's test reads 1; Juango's key stores the to_field's own stored value, the user's username)
    @test FormSet(; instance = profile).forms[1].instance.profile_id == "guido"
  end
  port_block() do
    # test_formset_with_none_instance
    Form = modelform_factory(DmfrUser; fields = "__all__")
    FormSet = inlineformset_factory(DmfrUser, DmfrUserSite; fields = "__all__")
    @test Form(; instance = nothing) !== nothing
    @test FormSet(; instance = nothing) !== nothing
    # test_empty_fields_on_modelformset
    UserFormSet = modelformset_factory(DmfrUser; fields = Symbol[])
    for form in UserFormSet().forms
        @test [x.name for x in form.fields] == [:id]
    end
    # test_save_as_new_with_new_inlines
    efnet = create(DmfrNetwork; name = "EFNet")
    host1 = create(DmfrHost; hostname = "irc.he.net", network = efnet)
    HostFormSet = inlineformset_factory(DmfrNetwork, DmfrHost; fields = "__all__")
    data = Dict("host_set-TOTAL_FORMS" => "2", "host_set-INITIAL_FORMS" => "1", "host_set-MAX_NUM_FORMS" => "0",
                "host_set-0-id" => string(host1.id), "host_set-0-hostname" => "tranquility.hub.dal.net",
                "host_set-1-hostname" => "matrix.de.eu.dal.net")
    dalnet = create(DmfrNetwork; name = "DALnet")
    fs = HostFormSet(data; instance = dalnet, save_as_new = true, prefix = "host_set")
    @test is_valid(fs)
    save!(fs)
    @test [h.hostname for h in collect(order_by(dalnet.dmfrhost_set, "hostname"))] == ["matrix.de.eu.dal.net", "tranquility.hub.dal.net"]
    @test get(DmfrHost; pk = host1.pk).hostname == "irc.he.net"
  end
  port_block() do
    # test_initial_data
    user = create(DmfrUser; username = "bibi", serial = 1)
    create(DmfrUserSite; user, data = 7)
    FormSet = inlineformset_factory(DmfrUser, DmfrUserSite; extra = 2, fields = "__all__")
    fs = FormSet(; instance = user, initial = [Dict(:data => 41), Dict(:data => 42)])
    @test fs.forms[1].initial[:data] == 7
    @test fs.forms[2].initial[:data] == 41
    @test occursin("value=\"42\"", string(as_p(fs.forms[3])))
  end
end

@testset "django model_formsets_regress: FormsetTests, FormfieldShouldDeleteFormTests, RedeleteTests" begin
  port_block() do
    # FormsetTests.test_initial_data
    create(DmfrUser; username = "bibi", serial = 1)
    Formset = modelformset_factory(DmfrUser; fields = "__all__", extra = 2)
    fs = Formset(; initial = [Dict(:username => "apollo11"), Dict(:username => "apollo12")])
    @test fs.forms[1].initial[:username] == "bibi"
    @test fs.forms[2].initial[:username] == "apollo11"
    @test occursin("value=\"apollo12\"", string(as_p(fs.forms[3])))
  end
  NormalFormset = modelformset_factory(DmfrUser; fields = "__all__", can_delete = true)
  base = Dict("form-TOTAL_FORMS" => "4", "form-INITIAL_FORMS" => "0", "form-MAX_NUM_FORMS" => "4",
              "form-0-username" => "John", "form-0-serial" => "1", "form-1-username" => "Paul", "form-1-serial" => "2",
              "form-2-username" => "George", "form-2-serial" => "3", "form-3-username" => "Ringo", "form-3-serial" => "5")
  init!() = (fs = NormalFormset(base); is_valid(fs) && length(save!(fs)) == 4)
  ids() = Dict("form-$(i-1)-id" => string(u.pk) for (i, u) in enumerate(collect(order_by(objects(DmfrUser), "pk"))))
  port_block() do
    @test init!()                                                                     # test_init_database
    # test_no_delete
    data = merge(base, Dict("form-INITIAL_FORMS" => "4"), ids())
    fs = NormalFormset(data; queryset = objects(DmfrUser))
    @test is_valid(fs) && length(save!(fs)) == 0 && count(objects(DmfrUser)) == 4
  end
  port_block() do
    # test_all_delete
    @test init!()
    data = merge(base, Dict("form-INITIAL_FORMS" => "4"), ids(), Dict("form-$i-DELETE" => "1" for i in 0:3))
    fs = NormalFormset(data; queryset = objects(DmfrUser))
    @test is_valid(fs) && length(save!(fs)) == 0 && count(objects(DmfrUser)) == 0
  end
  for already_deleted in (false, true)
    port_block() do
      # test_resubmit / test_delete_already_deleted
      u = create(DmfrUser; username = "foo", serial = 1)
      us = create(DmfrUserSite; user = u, data = 7)
      formset_cls = inlineformset_factory(DmfrUser, DmfrUserSite; fields = "__all__")
      data = Dict("serial" => "1", "username" => "foo", "usersite_set-TOTAL_FORMS" => "1", "usersite_set-INITIAL_FORMS" => "1",
                  "usersite_set-MAX_NUM_FORMS" => "1", "usersite_set-0-id" => string(us.pk), "usersite_set-0-data" => "7",
                  "usersite_set-0-user" => "foo", "usersite_set-0-DELETE" => "1")
      fs = formset_cls(data; instance = u, prefix = "usersite_set")
      already_deleted && delete!(us)
      @test is_valid(fs)
      save!(fs)
      @test count(objects(DmfrUserSite)) == 0
      if !already_deleted          # the same data again: the object is gone, the form still validates
          fs = formset_cls(data; instance = u, prefix = "usersite_set")
          @test is_valid(fs)
          save!(fs)
          @test count(objects(DmfrUserSite)) == 0
      end
    end
  end
end
