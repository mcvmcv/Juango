# Django's validation tests (tests/validation), translated (#227).
#
# Juango's full_clean returns the errors (a Dict, empty when valid) where Django's raises ValidationError with
# them, so Django's assertFailsValidation(clean, fields) is `dva_fails(obj) == fields`.
#
# Not translated: GetUniqueCheckTests (Model._get_unique_checks, an internal API), the "_adding" query-count
# tests of PerformUniqueChecksTest (Django's ModelState), the db_default expression tests (Now() as a db_default
# needs supports_expression_defaults; Juango's validate_unique skips DB_DEFAULT values), test_picklable
# (Python's pickle) and the lazy() value of test_invalid_generic_ip_raises_error.

using Dates

# --- tests/validation/models.py ---------------------------------------------------------------------------
dva_answer(v) = v == 42 ? true : throw(ValidationError("This is not the answer to life, universe and everything!"; code = "not42"))
@model struct DvaUniqueFieldsModel
    unique_charfield = CharField(max_length = 100, unique = true)
    unique_integerfield = IntegerField(unique = true, db_default = 42)
    non_unique_field = IntegerField()
    Meta(table = "dva_uniquefieldsmodel")
end
@model struct DvaModelToValidate
    name = CharField(max_length = 100)
    created = DateTimeField(default = () -> now())
    number = IntegerField(db_column = "number_val")
    parent = ForeignKey(:self; on_delete = :SET_NULL, blank = true, null = true, limit_choices_to = Dict(:number => 10))
    email = EmailField(blank = true)
    ufm = ForeignKey(DvaUniqueFieldsModel; on_delete = :SET_NULL, to_field = :unique_charfield, blank = true, null = true)
    url = URLField(blank = true)
    f_with_custom_validator = IntegerField(blank = true, null = true, validators = [dva_answer])
    f_with_iterable_of_validators = IntegerField(blank = true, null = true, validators = (dva_answer,))
    slug = SlugField(blank = true)
    Meta(table = "dva_modeltovalidate")
end
Juango.clean(m::DvaModelToValidate) = m.number == 11 ? throw(ValidationError("Invalid number supplied!")) : nothing
@model struct DvaCustomPKModel
    my_pk_field = CharField(max_length = 100, primary_key = true)
    Meta(table = "dva_custompkmodel")
end
@model struct DvaUniqueTogetherModel
    cfield = CharField(max_length = 100)
    ifield = IntegerField()
    efield = EmailField()
    Meta(table = "dva_uniquetogethermodel", unique_together = [(:ifield, :cfield), (:ifield, :efield)])
end
@model struct DvaCustomMessagesModel
    other = IntegerField(blank = true, null = true)
    number = IntegerField(db_column = "number_val", error_messages = Dict("null" => "NULL", "not42" => "AAARGH", "not_equal" => "%s != me"),
                          validators = [dva_answer])
    Meta(table = "dva_custommessagesmodel")
end
@model struct DvaAuthor
    name = CharField(max_length = 100)
    archived = BooleanField(default = false)
    Meta(table = "dva_author")
end
Juango.default_queryset(::Type{DvaAuthor}) = filter(base_objects(DvaAuthor); archived = false)     # AuthorManager
@model struct DvaArticle
    title = CharField(max_length = 100)
    author = ForeignKey(DvaAuthor; on_delete = :CASCADE)
    pub_date = DateTimeField(blank = true)
    Meta(table = "dva_article")
end
Juango.clean(a::DvaArticle) = (a.pub_date === nothing && (a.pub_date = now()); nothing)
@model struct DvaPost
    title = CharField(max_length = 50, unique_for_date = "posted", blank = true)
    slug = CharField(max_length = 50, unique_for_year = "posted", blank = true)
    subtitle = CharField(max_length = 50, unique_for_month = "posted", blank = true)
    posted = DateField()
    Meta(table = "dva_post")
end
@model struct DvaFlexibleDatePost
    title = CharField(max_length = 50, unique_for_date = "posted", blank = true)
    slug = CharField(max_length = 50, unique_for_year = "posted", blank = true)
    subtitle = CharField(max_length = 50, unique_for_month = "posted", blank = true)
    posted = DateField(blank = true, null = true)
    Meta(table = "dva_flexibledatepost")
end
@model struct DvaUniqueErrorsModel
    name = CharField(max_length = 100, unique = true, error_messages = Dict("unique" => "Custom unique name message."))
    no = IntegerField(unique = true, error_messages = Dict("unique" => "Custom unique number message."))
    Meta(table = "dva_uniqueerrorsmodel")
end
@model struct DvaGenericIPAddressTestModel
    generic_ip = GenericIPAddressField(blank = true, null = true, unique = true)
    v4_ip = GenericIPAddressField(blank = true, null = true, protocol = "ipv4")
    v6_ip = GenericIPAddressField(blank = true, null = true, protocol = "ipv6")
    ip_verbose_name = GenericIPAddressField(verbose_name = "IP Address Verbose", blank = true, null = true)
    Meta(table = "dva_genericipaddresstestmodel")
end
@model struct DvaGenericIPAddrUnpackUniqueTest
    generic_v4unpack_ip = GenericIPAddressField(null = true, blank = true, unique = true, unpack_ipv4 = true)
    Meta(table = "dva_genericipaddrunpackuniquetest")
end
@model struct DvaProduct
    price = IntegerField(null = true)
    discounted_price = IntegerField(null = true)
    Meta(table = "dva_product",
         constraints = [CheckConstraint(; condition = Q(price__gt = F(:discounted_price)), name = "price_gt_discounted_price_validation")])
end
@model struct DvaChildProduct <: DvaProduct
    Meta(table = "dva_childproduct")
end
@model struct DvaUniqueConstraintProduct
    name = CharField(max_length = 255)
    color = CharField(max_length = 32)
    rank = IntegerField()
    Meta(table = "dva_uniqueconstraintproduct",
         constraints = [UniqueConstraint(; fields = [:name, :color], name = "name_color_uniq_validation"),
                        UniqueConstraint(; fields = [:rank], name = "rank_uniq_validation")])
end
@model struct DvaChildUniqueConstraintProduct <: DvaUniqueConstraintProduct
    Meta(table = "dva_childuniqueconstraintproduct")
end
@model struct DvaUniqueConstraintConditionProduct
    name = CharField(max_length = 255)
    color = CharField(max_length = 31, null = true, blank = true)
    Meta(table = "dva_uniqueconstraintconditionproduct",
         constraints = [UniqueConstraint(; fields = [:name], name = "name_without_color_uniq_validation", condition = Q(color__isnull = true))])
end

redirect_stdout(devnull) do
    ms = Any[DvaUniqueFieldsModel, DvaModelToValidate, DvaCustomPKModel, DvaUniqueTogetherModel, DvaCustomMessagesModel, DvaAuthor,
             DvaArticle, DvaPost, DvaFlexibleDatePost, DvaUniqueErrorsModel, DvaGenericIPAddressTestModel, DvaGenericIPAddrUnpackUniqueTest,
             DvaProduct, DvaChildProduct, DvaUniqueConstraintProduct, DvaChildUniqueConstraintProduct, DvaUniqueConstraintConditionProduct]
    Juango.sync_models!(ms); append!(PORT_MODELS, ms)
end

dva_fails(obj; kw...) = sort(string.(collect(keys(full_clean(obj; kw...)))))
dva_msgs(obj, field; kw...) = get(full_clean(obj; kw...), field, String[])

@testset "django validation: BaseModelValidationTests, TestModelsWithValidators, CustomMessagesTests" begin
  port_block() do
    M = DvaModelToValidate
    # test_missing_required_field_raises_error
    @test dva_fails(M(; f_with_custom_validator = 42)) == ["name", "number"]
    # test_with_correct_value_model_validates
    @test isempty(full_clean(M(; number = 10, name = "Some Name")))
    # test_custom_validate_method
    @test dva_fails(M(; number = 11)) == ["__all__", "name"]
    # test_wrong_FK_value_raises_error
    mtv = M(; number = 10, name = "Some Name", parent_id = 3)
    @test dva_msgs(mtv, :parent) == ["dva model to validate instance with id 3 is not a valid choice."]
    mtv = M(; number = 10, name = "Some Name", ufm_id = "Some Name")
    @test dva_msgs(mtv, :ufm) == ["dva unique fields model instance with unique_charfield \"Some Name\" is not a valid choice."]
    # test_correct_FK_value_validates
    parent = create(M; number = 10, name = "Some Name")
    @test isempty(full_clean(M(; number = 10, name = "Some Name", parent_id = parent.pk)))
    # test_limited_FK_raises_error
    parent = create(M; number = 11, name = "Other Name")
    @test dva_fails(M(; number = 10, name = "Some Name", parent_id = parent.pk)) == ["parent"]
    # test_FK_validates_using_base_manager
    author = create(DvaAuthor; name = "Randy", archived = true)
    @test isempty(full_clean(DvaArticle(; title = "My Article", author = author)))
    # test_wrong_email_value_raises_error / test_correct_email_value_passes
    @test dva_fails(M(; number = 10, name = "Some Name", email = "not-an-email")) == ["email"]
    @test isempty(full_clean(M(; number = 10, name = "Some Name", email = "valid@email.com")))
    # test_wrong_url_value_raises_error
    @test dva_msgs(M(; number = 10, name = "Some Name", url = "not a url"), :url) == ["Enter a valid URL."]
    # test_text_greater_that_charfields_max_length_raises_errors / test_malformed_slug_raises_error
    @test dva_fails(M(; number = 10, name = "Some Name"^100)) == ["name"]
    @test dva_fails(M(; number = 10, name = "Some Name", slug = "##invalid##")) == ["slug"]
    # test_full_clean_does_not_mutate_exclude
    ex = [:number]
    @test dva_fails(M(; f_with_custom_validator = 42); exclude = ex) == ["name"]
    @test ex == [:number]
    # TestModelsWithValidators
    @test isempty(full_clean(M(; number = 10, name = "Some Name", f_with_custom_validator = 42, f_with_iterable_of_validators = 42)))
    m = M(; number = 10, name = "Some Name", f_with_custom_validator = 12, f_with_iterable_of_validators = 42)
    @test dva_fails(m) == ["f_with_custom_validator"]
    @test dva_msgs(m, :f_with_custom_validator) == ["This is not the answer to life, universe and everything!"]
    m = M(; number = 10, name = "Some Name", f_with_custom_validator = 42, f_with_iterable_of_validators = 12)
    @test dva_fails(m) == ["f_with_iterable_of_validators"]
    @test dva_msgs(m, :f_with_iterable_of_validators) == ["This is not the answer to life, universe and everything!"]
    # CustomMessagesTests
    @test dva_msgs(DvaCustomMessagesModel(; number = 12), :number) == ["AAARGH"]
    @test dva_msgs(DvaCustomMessagesModel(), :number) == ["NULL"]
  end
end

@testset "django validation: ModelFormsTests" begin
  port_block() do
    author = create(DvaAuthor; name = "Joseph Kocherhans")
    ArticleForm = modelform_factory(DvaArticle; exclude = [:author])
    # test_partial_validation
    form = ArticleForm(Dict("title" => "The state of model validation", "pub_date" => "2010-1-10 14:49:00"))
    @test is_valid(form) && isempty(form.errors)
    article = save!(form; commit = false)
    article.author = author
    save!(article)
    @test article.pk !== nothing
    # test_validation_with_empty_blank_field: Article.clean fills pub_date
    form = ArticleForm(Dict("title" => "The state of model validation"); instance = DvaArticle(; author_id = author.id))
    @test is_valid(form) && isempty(form.errors)
    @test form.instance.pub_date !== nothing
    @test save!(form).pk !== nothing
    # test_validation_with_invalid_blank_field
    form = ArticleForm(Dict("title" => "The state of model validation", "pub_date" => "never"); instance = DvaArticle(; author_id = author.id))
    @test !is_valid(form) && collect(keys(form.errors)) == [:pub_date]
  end
end

@testset "django validation: GenericIPAddressFieldTests" begin
  port_block() do
    G = DvaGenericIPAddressTestModel
    # test_correct_generic_ip_passes
    for ip in ("1.2.3.4", " 1.2.3.4 ", "1.2.3.4\n", "2001::2")
        @test isempty(full_clean(G(; generic_ip = ip)))
    end
    # test_invalid_generic_ip_raises_error
    for ip in ("294.4.2.1", "1:2", 1)
        @test dva_fails(G(; generic_ip = ip)) == ["generic_ip"]
    end
    # test_correct_v4_ip_passes / test_invalid_v4_ip_raises_error
    @test isempty(full_clean(G(; v4_ip = "1.2.3.4")))
    @test dva_fails(G(; v4_ip = "294.4.2.1")) == ["v4_ip"] && dva_fails(G(; v4_ip = "2001::2")) == ["v4_ip"]
    # test_correct_v6_ip_passes / test_invalid_v6_ip_raises_error
    @test isempty(full_clean(G(; v6_ip = "2001::2")))
    @test dva_fails(G(; v6_ip = "1.2.3.4")) == ["v6_ip"] && dva_fails(G(; v6_ip = "1:2")) == ["v6_ip"]
    # test_v6_uniqueness_detection: the same address written two ways
    save!(G(; generic_ip = "2001::1:0:0:0:0:2"))
    @test dva_fails(G(; generic_ip = "2001:0:1:2")) == ["generic_ip"]
    # test_v4_unpack_uniqueness_detection
    save!(G(; generic_ip = "::ffff:10.10.10.10"))
    @test isempty(full_clean(G(; generic_ip = "10.10.10.10")))
    save!(DvaGenericIPAddrUnpackUniqueTest(; generic_v4unpack_ip = "::ffff:18.52.18.52"))
    @test dva_fails(DvaGenericIPAddrUnpackUniqueTest(; generic_v4unpack_ip = "18.52.18.52")) == ["generic_v4unpack_ip"]
    # test_empty_generic_ip_passes
    @test isempty(full_clean(G(; generic_ip = ""))) && isempty(full_clean(G(; generic_ip = nothing)))
    # test_multiple_invalid_ip_raises_error
    g = G(; v6_ip = "1.2.3.4", v4_ip = "::ffff:10.10.10.10", generic_ip = "fsad")
    @test dva_msgs(g, :v6_ip) == ["Enter a valid IPv6 address."]
    @test dva_msgs(g, :v4_ip) == ["Enter a valid IPv4 address."]
    @test dva_msgs(g, :generic_ip) == ["Enter a valid IPv4 or IPv6 address."]
  end
end

@testset "django validation: PerformUniqueChecksTest" begin
  port_block() do
    # test_unique_db_default
    create(DvaUniqueFieldsModel; unique_charfield = "foo", non_unique_field = 42)
    @test full_clean(DvaUniqueFieldsModel(; unique_charfield = "bar", non_unique_field = 42)) ==
          Dict(:unique_integerfield => ["Dva unique fields model with this Unique integerfield already exists."])
    # test_unique_for_date
    create(DvaPost; title = "Django 1.0 is released", slug = "Django 1.0", subtitle = "Finally", posted = Date(2008, 9, 3))
    @test full_clean(DvaPost(; title = "Django 1.0 is released", posted = Date(2008, 9, 3))) ==
          Dict(:title => ["Title must be unique for Posted date."])
    @test isempty(full_clean(DvaPost(; title = "Work on Django 1.1 begins", posted = Date(2008, 9, 3))))
    @test isempty(full_clean(DvaPost(; title = "Django 1.0 is released", posted = Date(2008, 9, 4))))
    @test full_clean(DvaPost(; slug = "Django 1.0", posted = Date(2008, 1, 1))) == Dict(:slug => ["Slug must be unique for Posted year."])
    @test full_clean(DvaPost(; subtitle = "Finally", posted = Date(2008, 9, 30))) ==
          Dict(:subtitle => ["Subtitle must be unique for Posted month."])
    @test full_clean(DvaPost(; title = "Django 1.0 is released")) == Dict(:posted => ["This field cannot be null."])
    # test_unique_for_date_with_nullable_date
    create(DvaFlexibleDatePost; title = "Django 1.0 is released", slug = "Django 1.0", subtitle = "Finally", posted = Date(2008, 9, 3))
    @test isempty(full_clean(DvaFlexibleDatePost(; title = "Django 1.0 is released")))
    @test isempty(full_clean(DvaFlexibleDatePost(; slug = "Django 1.0")))
    @test isempty(full_clean(DvaFlexibleDatePost(; subtitle = "Finally")))
    # test_unique_errors
    create(DvaUniqueErrorsModel; name = "Some Name", no = 10)
    @test full_clean(DvaUniqueErrorsModel(; name = "Some Name", no = 11)) == Dict(:name => ["Custom unique name message."])
    @test full_clean(DvaUniqueErrorsModel(; name = "Some Other Name", no = 10)) == Dict(:no => ["Custom unique number message."])
    # (a primary key given by hand is unique too)
    create(DvaCustomPKModel; my_pk_field = "a")
    @test dva_fails(DvaCustomPKModel(; my_pk_field = "a")) == ["my_pk_field"]
    # unique_together
    create(DvaUniqueTogetherModel; cfield = "c", ifield = 1, efield = "a@b.cd")
    @test dva_fails(DvaUniqueTogetherModel(; cfield = "c", ifield = 1, efield = "x@y.zz")) == ["__all__"]
    @test isempty(full_clean(DvaUniqueTogetherModel(; cfield = "d", ifield = 1, efield = "x@y.zz")))
  end
end

@testset "django validation: PerformConstraintChecksTest" begin
  port_block() do
    # test_full_clean_with_check_constraints (and on the child model) / ..._disabled
    for P in (DvaProduct, DvaChildProduct)
        @test full_clean(P(; price = 10, discounted_price = 15)) ==
              Dict(:__all__ => ["Constraint “price_gt_discounted_price_validation” is violated."])
    end
    @test isempty(full_clean(DvaProduct(; price = 10, discounted_price = 15); validate_constraints = false))
    # test_full_clean_with_unique_constraints (and on the child model) / ..._disabled
    create(DvaUniqueConstraintProduct; name = "product", color = "yellow", rank = 1)
    for P in (DvaUniqueConstraintProduct, DvaChildUniqueConstraintProduct)
        @test full_clean(P(; name = "product", color = "yellow", rank = 1)) ==
              Dict(:__all__ => ["Dva unique constraint product with this Name and Color already exists."],
                   :rank => ["Dva unique constraint product with this Rank already exists."])   # (the verbose name of DvaUniqueConstraintProduct)
    end
    @test isempty(full_clean(DvaUniqueConstraintProduct(; name = "product", color = "yellow", rank = 1); validate_constraints = false))
    # test_full_clean_with_partial_unique_constraints / ..._disabled
    create(DvaUniqueConstraintConditionProduct; name = "product")
    @test full_clean(DvaUniqueConstraintConditionProduct(; name = "product")) ==
          Dict(:__all__ => ["Constraint “name_without_color_uniq_validation” is violated."])
    @test isempty(full_clean(DvaUniqueConstraintConditionProduct(; name = "product"); validate_constraints = false))
  end
end

@testset "django validation: ValidationMessagesTest" begin
    msgs(f, v) = try
        Juango.clean_value(f, v); String[]
    catch e
        e isa ValidationError || rethrow()
        e.messages
    end
    @test msgs(IntegerField(), "fõo") == ["“fõo” value must be an integer."]
    @test msgs(BooleanField(), "fõo") == ["“fõo” value must be either True or False."]
    @test msgs(BooleanField(null = true), "fõo") == ["“fõo” value must be either True, False, or None."]
    @test msgs(FloatField(), "fõo") == ["“fõo” value must be a float."]
    @test msgs(DecimalField(max_digits = 5, decimal_places = 2), "fõo") == ["“fõo” value must be a decimal number."]
    @test msgs(DateField(), "fõo") == ["“fõo” value has an invalid date format. It must be in YYYY-MM-DD format."]
    @test msgs(DateField(), "aaaa-10-10") == ["“aaaa-10-10” value has an invalid date format. It must be in YYYY-MM-DD format."]
    @test msgs(DateField(), "2011-13-10") == ["“2011-13-10” value has the correct format (YYYY-MM-DD) but it is an invalid date."]
    @test msgs(DateField(), "2011-10-32") == ["“2011-10-32” value has the correct format (YYYY-MM-DD) but it is an invalid date."]
    @test msgs(DateTimeField(), "fõo") == ["“fõo” value has an invalid format. It must be in YYYY-MM-DD HH:MM[:ss[.uuuuuu]][TZ] format."]
    @test msgs(DateTimeField(), "2011-10-32") == ["“2011-10-32” value has the correct format (YYYY-MM-DD) but it is an invalid date."]
    @test msgs(DateTimeField(), "2011-10-32 10:10") ==
          ["“2011-10-32 10:10” value has the correct format (YYYY-MM-DD HH:MM[:ss[.uuuuuu]][TZ]) but it is an invalid date/time."]
    @test msgs(TimeField(), "fõo") == ["“fõo” value has an invalid format. It must be in HH:MM[:ss[.uuuuuu]] format."]
    @test msgs(TimeField(), "25:50") == ["“25:50” value has the correct format (HH:MM[:ss[.uuuuuu]]) but it is an invalid time."]
    # (and the values they accept)
    @test Juango.clean_value(DateField(), "2011-10-02") == Date(2011, 10, 2)
    @test Juango.clean_value(DateTimeField(), "2011-10-02 10:10") == DateTime(2011, 10, 2, 10, 10)
    @test Juango.clean_value(TimeField(), "10:10:05") == Time(10, 10, 5)
end
