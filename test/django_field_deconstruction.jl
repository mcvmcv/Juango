# Django's field_deconstruction tests, ported (#227): FieldDeconstructionTests. Django's migrations record each field's
# deconstruct() (path, args, kwargs); Juango's record the column a field makes (`column_state`), written as
# `Column(...)` code (`Migrations.column_code`). So the checks here are the database half of Django's: max_length,
# null, default, decimal digits, the column a key refers to, unique and indexes.
# julia --project=test test/django_field_deconstruction.jl   (see setup.jl)
#
# Not translated: the attributes that don't change the database (choices, blank, auto_now, auto_now_add, upload_to,
# related_name, related_query_name, limit_choices_to, on_delete, FilePathField's match/recursive), which Juango's
# migrations leave out by design; test_name and the field paths (a Column has no class path); swappable models
# (Juango has no AUTH_USER_MODEL swapping in migrations); db_tablespace (Juango has none); CommaSeparatedIntegerField
# and IPAddressField (removed in Django too).
@isdefined(TEST_SETUP_DONE) || include("setup.jl")

@model struct DfdTarget
    name::String = CharField(max_length = 10, unique = true)
    Meta(table = "dfd_target")
end
@model struct DfdAll
    char::String = CharField(max_length = 65)
    charn::Union{String,Nothing} = CharField(max_length = 65, null = true, blank = true)
    choice::String = CharField(max_length = 1, choices = [("A", "One"), ("B", "Two")])
    big::Int = BigIntegerField()
    boo::Bool = BooleanField()
    boot::Bool = BooleanField(default = true)
    date::Date = DateField(auto_now = true)
    dt::DateTime = DateTimeField(auto_now = true, auto_now_add = true)
    dec::Decimal = DecimalField(max_digits = 5, decimal_places = 2)
    dec0::Decimal = DecimalField(max_digits = 5, decimal_places = 0)
    email::String = EmailField()
    email2::String = EmailField(max_length = 255)
    file::String = FileField(upload_to = "foo/bar")
    file2::String = FileField(upload_to = "foo/bar", max_length = 200)
    img::String = ImageField(upload_to = "foo/bar")
    flt::Float64 = FloatField()
    fk::Int = ForeignKey(DfdTarget, on_delete = :CASCADE)
    fkn::Union{Int,Nothing} = ForeignKey(DfdTarget, on_delete = :SET_NULL, null = true, related_name = "foobar")
    fku::Int = ForeignKey(DfdTarget, on_delete = :CASCADE, unique = true, related_name = "u")
    fkt::String = ForeignKey(DfdTarget, on_delete = :CASCADE, to_field = :name, related_name = "t")
    o2o::Int = OneToOneField(DfdTarget, on_delete = :CASCADE, related_name = "o")
    int::Int = IntegerField()
    ip::String = GenericIPAddressField()
    pint::Int = PositiveIntegerField()
    psint::Int = PositiveSmallIntegerField()
    pbint::Int = PositiveBigIntegerField()
    slug::String = SlugField()
    slug2::String = SlugField(db_index = false)
    slug3::String = SlugField(max_length = 231)
    sint::Int = SmallIntegerField()
    text::String = TextField()
    time::Time = TimeField()
    url::String = URLField()
    url2::String = URLField(max_length = 231)
    bin::Vector{UInt8} = BinaryField()
    bin2::Vector{UInt8} = BinaryField(editable = true)
    Meta(table = "dfd_all")
end

"The migration code of a field's column, without the column name (Django's deconstruct() kwargs, roughly)."
function dfd(name)
    code = Juango.Migrations.column_code(Juango.column_state(Juango.getfield_meta(DfdAll, name)))
    replace(code, r"^Column\(\"[^\"]*\", " => "", r"\)$" => "")
end

@testset "django field_deconstruction: FieldDeconstructionTests" begin
    @test dfd(:char) == ":string; max_length = 65"                                # test_char_field
    @test dfd(:charn) == ":string; null = true, max_length = 65"
    @test dfd(:choice) == ":string; max_length = 1"                               # test_char_field_choices (choices: not a column's)
    @test dfd(:big) == ":bigint"                                                  # test_big_integer_field
    @test dfd(:boo) == ":bool; default = false"                                   # test_boolean_field (Juango's defaults to false)
    @test dfd(:boot) == ":bool; default = true"
    @test dfd(:date) == ":date"                                                   # test_date_field
    @test dfd(:dt) == ":datetime"                                                 # test_datetime_field (#21785)
    @test dfd(:dec) == ":decimal; max_digits = 5, decimal_places = 2"             # test_decimal_field
    @test dfd(:dec0) == ":decimal; max_digits = 5, decimal_places = 0"            # test_decimal_field_0_decimal_places (#22272)
    @test dfd(:email) == ":string; max_length = 254"                              # test_email_field
    @test dfd(:email2) == ":string; max_length = 255"
    @test dfd(:file) == ":string; max_length = 100"                               # test_file_field
    @test dfd(:file2) == ":string; max_length = 200"
    @test dfd(:img) == ":string; max_length = 100"                                # test_image_field
    @test dfd(:flt) == ":float"                                                   # test_float_field
    t = Juango.modelmeta(DfdTarget).table                                          # test_foreign_key
    @test dfd(:fk) == ":fk; index = true, references = $(repr(t))"
    @test dfd(:fkn) == ":fk; null = true, index = true, references = $(repr(t))"
    @test dfd(:fku) == ":fk; unique = true, references = $(repr(t))"              # (unique: no second index)
    @test occursin("references = $(repr(t))", dfd(:fkt)) && occursin("ref_column = \"name\"", dfd(:fkt))  # to_field
    @test dfd(:o2o) == ":fk; unique = true, references = $(repr(t))"              # test_one_to_one
    @test dfd(:int) == ":int"                                                     # test_integer_field
    @test dfd(:ip) == ":ipaddress"                                                # test_generic_ip_address_field
    @test dfd(:pint) == ":posint"                                                 # test_positive_integer_field
    @test dfd(:psint) == ":possmallint"                                           # test_positive_small_integer_field
    @test dfd(:pbint) == ":posbigint"                                             # test_positive_big_integer_field
    @test dfd(:slug) == ":string; index = true, max_length = 50"                  # test_slug_field
    @test dfd(:slug2) == ":string; max_length = 50"
    @test dfd(:slug3) == ":string; index = true, max_length = 231"
    @test dfd(:sint) == ":smallint"                                               # test_small_integer_field
    @test dfd(:text) == ":string"                                                 # test_text_field
    @test dfd(:time) == ":time"                                                   # test_time_field
    @test dfd(:url) == ":string; max_length = 200"                                # test_url_field
    @test dfd(:url2) == ":string; max_length = 231"
    @test dfd(:bin) == ":binary" && dfd(:bin2) == ":binary"                       # test_binary_field
    # each column reads back from its code as the same column (the round trip Django's deconstruct() is for)
    for f in Juango.modelmeta(DfdAll).fields
        c = Juango.column_state(f)
        @test Core.eval(Juango.Migrations, Meta.parse(Juango.Migrations.column_code(c))) == c
    end
end
